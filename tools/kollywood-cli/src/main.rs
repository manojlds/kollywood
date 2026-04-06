use anyhow::{bail, Context, Result};
use clap::{Args, Parser, Subcommand, ValueEnum};
use reqwest::blocking::{Client, Response};
use reqwest::StatusCode;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{self, Read};
use urlencoding::encode;

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let api = ApiClient::new(&cli.api_url)?;

    match cli.command {
        Commands::Story(story) => run_story_command(&api, story),
        Commands::Project(project) => run_project_command(&api, project),
        Commands::Workflow(workflow) => run_workflow_command(&api, workflow),
    }
}

const VERSION_FULL: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    "+",
    env!("KOLLYWOOD_CLI_GIT_SHA")
);

fn run_story_command(api: &ApiClient, story: StoryArgs) -> Result<()> {
    match story.command {
        StoryCommand::List(args) => {
            let project = resolve_project_slug(api, args.project.as_deref())?;
            let stories = api.list_stories(&project)?;
            print_stories(&stories, args.json)
        }
        StoryCommand::Add(args) => {
            let project = resolve_project_slug(api, args.project.as_deref())?;
            let payload = build_add_payload(&args)?;
            let story = api.create_story(&project, payload)?;
            print_story("Created", &story, args.json)
        }
        StoryCommand::Edit(args) => {
            let project = resolve_project_slug(api, args.project.as_deref())?;
            let payload = build_edit_payload(&args)?;
            let story = api.update_story(&project, &args.story_id, payload)?;
            print_story("Updated", &story, args.json)
        }
        StoryCommand::Delete(args) => {
            let project = resolve_project_slug(api, args.project.as_deref())?;
            api.delete_story(&project, &args.story_id)?;

            if args.json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&json!({"deleted": args.story_id}))
                        .context("failed to render JSON output")?
                );
            } else {
                println!("Deleted story {}", args.story_id);
            }

            Ok(())
        }
        StoryCommand::Export(args) => {
            let project = resolve_project_slug(api, args.project.as_deref())?;
            run_story_export(api, args, &project)
        }
        StoryCommand::Import(args) => {
            let project = resolve_project_slug(api, args.project.as_deref())?;
            run_story_import(api, args, &project)
        }
    }
}

fn run_project_command(api: &ApiClient, project: ProjectArgs) -> Result<()> {
    match project.command {
        ProjectCommand::Resolve(args) => {
            let path = match clean_optional(args.path.as_deref()) {
                Some(path) => path,
                None => {
                    let cwd = std::env::current_dir()
                        .context("failed to read current working directory")?;
                    cwd.to_str()
                        .context("current working directory contains invalid UTF-8")?
                        .to_string()
                }
            };

            let resolved = api
                .resolve_project(&path)
                .with_context(|| format!("failed to resolve project from path {path}"))?;

            print_resolved_project(&resolved, args.json)
        }
    }
}

fn run_workflow_command(api: &ApiClient, workflow: WorkflowArgs) -> Result<()> {
    match workflow.command {
        WorkflowCommand::Schema(args) => {
            let schema = api.fetch_workflow_schema()?;
            print_workflow_schema(&schema, args.json)
        }
    }
}

#[derive(Parser, Debug)]
#[command(
    name = "kollywood",
    version = VERSION_FULL,
    about = "Kollywood CLI"
)]
struct Cli {
    #[arg(
        long = "api",
        global = true,
        env = "KOLLYWOOD_API",
        default_value = "http://127.0.0.1:4000",
        help = "Kollywood API base URL"
    )]
    api_url: String,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Story(StoryArgs),
    Project(ProjectArgs),
    Workflow(WorkflowArgs),
}

#[derive(Args, Debug)]
struct StoryArgs {
    #[command(subcommand)]
    command: StoryCommand,
}

#[derive(Subcommand, Debug)]
enum StoryCommand {
    List(StoryListArgs),
    Add(StoryAddArgs),
    Edit(StoryEditArgs),
    Delete(StoryDeleteArgs),
    Export(StoryExportArgs),
    Import(StoryImportArgs),
}

#[derive(Args, Debug)]
struct ProjectArgs {
    #[command(subcommand)]
    command: ProjectCommand,
}

#[derive(Subcommand, Debug)]
enum ProjectCommand {
    Resolve(ProjectResolveArgs),
}

#[derive(Args, Debug)]
struct WorkflowArgs {
    #[command(subcommand)]
    command: WorkflowCommand,
}

#[derive(Subcommand, Debug)]
enum WorkflowCommand {
    Schema(WorkflowSchemaArgs),
}

#[derive(Args, Debug)]
struct WorkflowSchemaArgs {
    #[arg(long, help = "Output raw JSON")]
    json: bool,
}

#[derive(Args, Debug)]
struct ProjectResolveArgs {
    #[arg(
        long,
        help = "Path to resolve against Kollywood projects (defaults to current directory)"
    )]
    path: Option<String>,

    #[arg(long, help = "Output raw JSON")]
    json: bool,
}

#[derive(Args, Debug)]
struct StoryListArgs {
    #[arg(
        long,
        help = "Project slug (auto-detected from current directory when omitted)"
    )]
    project: Option<String>,

    #[arg(long, help = "Output raw JSON")]
    json: bool,
}

#[derive(Args, Debug)]
struct StoryAddArgs {
    #[arg(
        long,
        help = "Project slug (auto-detected from current directory when omitted)"
    )]
    project: Option<String>,

    #[arg(long, help = "Story title")]
    title: String,

    #[arg(long, help = "Optional story id (for example US-123)")]
    id: Option<String>,

    #[arg(long, help = "Optional initial status (draft or open)")]
    status: Option<String>,

    #[arg(long, help = "Optional numeric priority")]
    priority: Option<u32>,

    #[arg(long, help = "Optional story description")]
    description: Option<String>,

    #[arg(long, help = "Optional story notes")]
    notes: Option<String>,

    #[arg(long = "testing-notes", help = "Optional notes for testing agent only")]
    testing_notes: Option<String>,

    #[arg(
        long = "depends-on",
        help = "Dependency story id; repeat or pass comma-separated values"
    )]
    depends_on: Vec<String>,

    #[arg(
        long = "acceptance",
        help = "Acceptance criterion; repeat for multiple"
    )]
    acceptance: Vec<String>,

    #[arg(long, help = "Output raw JSON")]
    json: bool,
}

#[derive(Args, Debug)]
struct StoryEditArgs {
    #[arg(
        long,
        help = "Project slug (auto-detected from current directory when omitted)"
    )]
    project: Option<String>,

    #[arg(help = "Story id to edit")]
    story_id: String,

    #[arg(long, help = "Updated title")]
    title: Option<String>,

    #[arg(long, help = "Updated status")]
    status: Option<String>,

    #[arg(long, help = "Updated numeric priority")]
    priority: Option<u32>,

    #[arg(long, help = "Updated description")]
    description: Option<String>,

    #[arg(long, help = "Updated notes")]
    notes: Option<String>,

    #[arg(long = "testing-notes", help = "Updated notes for testing agent only")]
    testing_notes: Option<String>,

    #[arg(
        long = "depends-on",
        help = "Set dependencies (repeatable or comma-separated)"
    )]
    depends_on: Vec<String>,

    #[arg(long, help = "Clear all dependencies")]
    clear_depends_on: bool,

    #[arg(
        long = "acceptance",
        help = "Set acceptance criteria (repeat for multiple)"
    )]
    acceptance: Vec<String>,

    #[arg(long, help = "Clear all acceptance criteria")]
    clear_acceptance: bool,

    #[arg(long, help = "Output raw JSON")]
    json: bool,
}

#[derive(Args, Debug)]
struct StoryDeleteArgs {
    #[arg(
        long,
        help = "Project slug (auto-detected from current directory when omitted)"
    )]
    project: Option<String>,

    #[arg(help = "Story id to delete")]
    story_id: String,

    #[arg(long, help = "Output raw JSON")]
    json: bool,
}

#[derive(Args, Debug)]
struct StoryExportArgs {
    #[arg(
        long,
        help = "Project slug (auto-detected from current directory when omitted)"
    )]
    project: Option<String>,

    #[arg(long, help = "Write JSON export to file path (defaults to stdout)")]
    output: Option<String>,

    #[arg(long, help = "Write compact JSON (default is pretty)")]
    compact: bool,
}

#[derive(Args, Debug)]
struct StoryImportArgs {
    #[arg(
        long,
        help = "Project slug (auto-detected from current directory when omitted)"
    )]
    project: Option<String>,

    #[arg(
        long,
        help = "Read JSON import from file path or '-' for stdin",
        default_value = "-"
    )]
    input: String,

    #[arg(
        long,
        value_enum,
        default_value_t = ImportMode::Upsert,
        help = "Import mode: create, update, or upsert"
    )]
    mode: ImportMode,

    #[arg(long, help = "Continue processing on per-record errors")]
    continue_on_error: bool,

    #[arg(long, help = "Validate and plan import without mutating stories")]
    dry_run: bool,

    #[arg(long, help = "Output summary as JSON")]
    json: bool,

    #[arg(
        long,
        help = "Delete stories not present in import payload (sync mode)"
    )]
    delete_missing: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum, Serialize)]
#[serde(rename_all = "snake_case")]
enum ImportMode {
    Create,
    Update,
    Upsert,
}

#[derive(Debug, Serialize)]
struct ImportSummary {
    mode: ImportMode,
    dry_run: bool,
    total: usize,
    created: usize,
    updated: usize,
    deleted: usize,
    failed: usize,
    errors: Vec<ImportError>,
}

#[derive(Debug, Serialize)]
struct ImportError {
    index: usize,
    story_id: Option<String>,
    message: String,
}

#[derive(Debug, Deserialize)]
struct DataEnvelope<T> {
    data: T,
}

#[derive(Debug, Deserialize)]
struct ErrorEnvelope {
    error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Story {
    #[serde(default)]
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    priority: Option<i64>,
    #[serde(default, rename = "dependsOn")]
    depends_on: Vec<String>,
    #[serde(default, rename = "acceptanceCriteria")]
    acceptance_criteria: Vec<String>,
    #[serde(default, rename = "allowed_status_transitions")]
    allowed_status_transitions: Vec<String>,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ResolvedProject {
    slug: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    local_path: Option<String>,
    #[serde(default)]
    repository: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkflowSchema {
    #[serde(default)]
    schema_version: String,
    #[serde(default)]
    workflow_front_matter: Value,
    #[serde(default)]
    sections: Map<String, Value>,
}

struct ApiClient {
    base_url: String,
    http: Client,
}

impl ApiClient {
    fn new(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/');

        if base_url.is_empty() {
            bail!("API URL cannot be empty");
        }

        let http = Client::builder()
            .build()
            .context("failed to initialize HTTP client")?;

        Ok(Self {
            base_url: base_url.to_string(),
            http,
        })
    }

    fn list_stories(&self, project: &str) -> Result<Vec<Story>> {
        let response = self
            .http
            .get(self.stories_url(project))
            .send()
            .context("failed to call list stories endpoint")?;

        let envelope: DataEnvelope<Vec<Story>> = parse_json_response(response)?;
        Ok(envelope.data)
    }

    fn resolve_project(&self, path: &str) -> Result<ResolvedProject> {
        let response = self
            .http
            .get(self.resolve_project_url(path))
            .send()
            .context("failed to call project resolve endpoint")?;

        let envelope: DataEnvelope<ResolvedProject> = parse_json_response(response)?;
        Ok(envelope.data)
    }

    fn create_story(&self, project: &str, payload: Value) -> Result<Story> {
        let response = self
            .http
            .post(self.stories_url(project))
            .json(&json!({ "story": payload }))
            .send()
            .context("failed to call create story endpoint")?;

        let envelope: DataEnvelope<Story> = parse_json_response(response)?;
        Ok(envelope.data)
    }

    fn fetch_workflow_schema(&self) -> Result<WorkflowSchema> {
        let response = self
            .http
            .get(self.workflow_schema_url())
            .send()
            .context("failed to call workflow schema endpoint")?;

        let envelope: DataEnvelope<WorkflowSchema> = parse_json_response(response)?;
        Ok(envelope.data)
    }

    fn update_story(&self, project: &str, story_id: &str, payload: Value) -> Result<Story> {
        let response = self
            .http
            .patch(self.story_url(project, story_id))
            .json(&json!({ "story": payload }))
            .send()
            .context("failed to call update story endpoint")?;

        let envelope: DataEnvelope<Story> = parse_json_response(response)?;
        Ok(envelope.data)
    }

    fn delete_story(&self, project: &str, story_id: &str) -> Result<()> {
        let response = self
            .http
            .delete(self.story_url(project, story_id))
            .send()
            .context("failed to call delete story endpoint")?;

        parse_empty_response(response)
    }

    fn stories_url(&self, project: &str) -> String {
        format!(
            "{}/api/projects/{}/stories",
            self.base_url,
            encode(project.trim())
        )
    }

    fn story_url(&self, project: &str, story_id: &str) -> String {
        format!(
            "{}/api/projects/{}/stories/{}",
            self.base_url,
            encode(project.trim()),
            encode(story_id.trim())
        )
    }

    fn resolve_project_url(&self, path: &str) -> String {
        format!(
            "{}/api/projects/resolve?path={}",
            self.base_url,
            encode(path.trim())
        )
    }

    fn workflow_schema_url(&self) -> String {
        format!("{}/api/workflow/schema", self.base_url)
    }
}

fn resolve_project_slug(api: &ApiClient, explicit_project: Option<&str>) -> Result<String> {
    if let Some(project) = explicit_project.and_then(clean_non_empty) {
        return Ok(project);
    }

    let cwd = std::env::current_dir().context("failed to read current working directory")?;
    let cwd = cwd
        .to_str()
        .context("current working directory contains invalid UTF-8")?;

    let project = api
        .resolve_project(cwd)
        .with_context(|| format!("failed to resolve project from current directory {cwd}"))?;

    clean_non_empty(&project.slug).context("resolved project has empty slug")
}

fn run_story_export(api: &ApiClient, args: StoryExportArgs, project: &str) -> Result<()> {
    let stories = api.list_stories(project)?;

    let mut export_stories = Vec::with_capacity(stories.len());
    for story in stories {
        let mut value =
            serde_json::to_value(story).context("failed to serialize story for export")?;

        if let Value::Object(map) = &mut value {
            map.remove("allowed_status_transitions");
        }

        export_stories.push(value);
    }

    let payload = json!({
        "project": project,
        "stories": export_stories
    });

    let rendered = if args.compact {
        serde_json::to_string(&payload).context("failed to render compact JSON")?
    } else {
        serde_json::to_string_pretty(&payload).context("failed to render pretty JSON")?
    };

    match args.output.as_deref() {
        Some(path) if path != "-" => {
            fs::write(path, rendered)
                .with_context(|| format!("failed to write export file {path}"))?;
            println!("Exported stories to {path}");
        }
        _ => {
            println!("{rendered}");
        }
    }

    Ok(())
}

fn run_story_import(api: &ApiClient, args: StoryImportArgs, project: &str) -> Result<()> {
    let source = read_import_source(&args.input)?;
    let records = parse_import_records(&source)?;
    let delete_missing_ids = if args.delete_missing {
        Some(plan_delete_missing(&records, args.mode)?)
    } else {
        None
    };

    let mut existing_ids =
        if matches!(args.mode, ImportMode::Upsert) || args.dry_run || args.delete_missing {
            let stories = api.list_stories(project)?;
            stories
                .into_iter()
                .filter_map(|story| clean_non_empty(&story.id))
                .collect::<HashSet<_>>()
        } else {
            HashSet::new()
        };

    let initial_existing_ids = existing_ids.clone();

    let mut summary = ImportSummary {
        mode: args.mode,
        dry_run: args.dry_run,
        total: records.len(),
        created: 0,
        updated: 0,
        deleted: 0,
        failed: 0,
        errors: Vec::new(),
    };

    for (index, record) in records.into_iter().enumerate() {
        let record_index = index + 1;
        let story_id = extract_story_id(&record);

        let result = apply_import_record(
            api,
            project,
            &record,
            args.mode,
            args.dry_run,
            &mut existing_ids,
        );

        match result {
            Ok(ImportAction::Created(id)) => {
                summary.created += 1;
                if let Some(id) = id {
                    existing_ids.insert(id);
                }
            }
            Ok(ImportAction::Updated(id)) => {
                summary.updated += 1;
                if let Some(id) = id {
                    existing_ids.insert(id);
                }
            }
            Err(error) => {
                summary.failed += 1;
                summary.errors.push(ImportError {
                    index: record_index,
                    story_id,
                    message: error.to_string(),
                });

                if !args.continue_on_error {
                    break;
                }
            }
        }
    }

    if args.delete_missing {
        if let Some(desired_ids) = &delete_missing_ids {
            apply_delete_missing(
                api,
                project,
                &args,
                &mut summary,
                desired_ids,
                &initial_existing_ids,
            )?;
        }
    }

    print_import_summary(&summary, args.json)?;

    if summary.failed > 0 {
        bail!("import completed with {} failure(s)", summary.failed);
    }

    Ok(())
}

fn apply_import_record(
    api: &ApiClient,
    project: &str,
    record: &Map<String, Value>,
    mode: ImportMode,
    dry_run: bool,
    existing_ids: &mut HashSet<String>,
) -> Result<ImportAction> {
    let story_id = extract_story_id(record);
    let operation = choose_import_operation(mode, story_id.as_deref(), existing_ids)?;

    match operation {
        ImportOperation::Create => {
            validate_create_record(record)?;

            if dry_run {
                Ok(ImportAction::Created(story_id))
            } else {
                let created = api.create_story(project, Value::Object(record.clone()))?;
                Ok(ImportAction::Created(
                    clean_non_empty(&created.id).or(story_id),
                ))
            }
        }
        ImportOperation::Update(id) => {
            validate_update_record(record)?;

            if dry_run {
                Ok(ImportAction::Updated(Some(id.to_string())))
            } else {
                let updated = api.update_story(project, id, Value::Object(record.clone()))?;
                Ok(ImportAction::Updated(
                    clean_non_empty(&updated.id).or(story_id),
                ))
            }
        }
    }
}

fn choose_import_operation<'a>(
    mode: ImportMode,
    story_id: Option<&'a str>,
    existing_ids: &HashSet<String>,
) -> Result<ImportOperation<'a>> {
    match mode {
        ImportMode::Create => Ok(ImportOperation::Create),
        ImportMode::Update => {
            let id = story_id.context("update mode requires story id")?;
            Ok(ImportOperation::Update(id))
        }
        ImportMode::Upsert => {
            if let Some(id) = story_id {
                if existing_ids.contains(id) {
                    Ok(ImportOperation::Update(id))
                } else {
                    Ok(ImportOperation::Create)
                }
            } else {
                Ok(ImportOperation::Create)
            }
        }
    }
}

fn plan_delete_missing(
    records: &[Map<String, Value>],
    mode: ImportMode,
) -> Result<HashSet<String>> {
    if matches!(mode, ImportMode::Create) {
        bail!("--delete-missing requires --mode update or --mode upsert");
    }

    let mut desired_ids = HashSet::new();

    for (index, record) in records.iter().enumerate() {
        let story_id = extract_story_id(record).with_context(|| {
            format!(
                "--delete-missing requires id for every record (missing at index {})",
                index + 1
            )
        })?;

        desired_ids.insert(story_id);
    }

    Ok(desired_ids)
}

fn apply_delete_missing(
    api: &ApiClient,
    project: &str,
    args: &StoryImportArgs,
    summary: &mut ImportSummary,
    desired_ids: &HashSet<String>,
    initial_existing_ids: &HashSet<String>,
) -> Result<()> {
    if summary.failed > 0 {
        summary.errors.push(ImportError {
            index: 0,
            story_id: None,
            message: "skipped delete-missing because import had failures".to_string(),
        });
        return Ok(());
    }

    if args.dry_run {
        summary.deleted = initial_existing_ids
            .iter()
            .filter(|story_id| !desired_ids.contains(*story_id))
            .count();
        return Ok(());
    }

    let existing_story_ids = api
        .list_stories(project)?
        .into_iter()
        .filter_map(|story| clean_non_empty(&story.id))
        .collect::<Vec<_>>();

    let mut deleted = 0usize;

    for story_id in existing_story_ids {
        if !desired_ids.contains(&story_id) {
            api.delete_story(project, &story_id)
                .with_context(|| format!("failed to delete story {} during sync", story_id))?;
            deleted += 1;
        }
    }

    summary.deleted = deleted;
    Ok(())
}

fn read_import_source(input: &str) -> Result<String> {
    let mut source = String::new();

    if input == "-" {
        io::stdin()
            .read_to_string(&mut source)
            .context("failed to read import payload from stdin")?;
    } else {
        source = fs::read_to_string(input)
            .with_context(|| format!("failed to read import file {input}"))?;
    }

    if source.trim().is_empty() {
        bail!("import payload is empty");
    }

    Ok(source)
}

fn parse_import_records(input: &str) -> Result<Vec<Map<String, Value>>> {
    let value: Value = serde_json::from_str(input).context("failed to parse import JSON")?;
    records_from_value(value)
}

fn records_from_value(value: Value) -> Result<Vec<Map<String, Value>>> {
    match value {
        Value::Array(items) => parse_story_object_array(items),
        Value::Object(mut map) => {
            if let Some(stories_value) = map.remove("stories") {
                match stories_value {
                    Value::Array(items) => parse_story_object_array(items),
                    _ => bail!("`stories` must be an array of objects"),
                }
            } else if looks_like_story_record(&map) {
                Ok(vec![map])
            } else {
                bail!("import JSON must be a story object, array of story objects, or object with `stories` array")
            }
        }
        _ => bail!("import JSON must be an object or array"),
    }
}

fn parse_story_object_array(items: Vec<Value>) -> Result<Vec<Map<String, Value>>> {
    let mut records = Vec::with_capacity(items.len());

    for (index, value) in items.into_iter().enumerate() {
        match value {
            Value::Object(map) => records.push(map),
            _ => bail!("stories[{}] must be a JSON object", index),
        }
    }

    Ok(records)
}

fn looks_like_story_record(record: &Map<String, Value>) -> bool {
    record.contains_key("id") || record.contains_key("title")
}

fn extract_story_id(record: &Map<String, Value>) -> Option<String> {
    record
        .get("id")
        .and_then(Value::as_str)
        .and_then(clean_non_empty)
}

fn validate_create_record(record: &Map<String, Value>) -> Result<()> {
    let title = record
        .get("title")
        .and_then(Value::as_str)
        .and_then(clean_non_empty)
        .context("create requires non-empty `title`")?;

    if title.is_empty() {
        bail!("create requires non-empty `title`");
    }

    Ok(())
}

fn validate_update_record(record: &Map<String, Value>) -> Result<()> {
    let has_update_field = [
        "title",
        "status",
        "priority",
        "description",
        "notes",
        "testingNotes",
        "testing_notes",
        "dependsOn",
        "depends_on",
        "acceptanceCriteria",
        "acceptance_criteria",
    ]
    .iter()
    .any(|key| record.contains_key(*key));

    if has_update_field {
        Ok(())
    } else {
        bail!(
            "update requires at least one mutable field (title/status/priority/description/notes/testingNotes/dependsOn/acceptanceCriteria)"
        )
    }
}

fn print_import_summary(summary: &ImportSummary, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(summary)
                .context("failed to render import JSON summary")?
        );
        return Ok(());
    }

    let mode = import_mode_name(summary.mode);

    println!(
        "Import {}: total {}, created {}, updated {}, deleted {}, failed {}{}",
        mode,
        summary.total,
        summary.created,
        summary.updated,
        summary.deleted,
        summary.failed,
        if summary.dry_run { " (dry-run)" } else { "" }
    );

    if !summary.errors.is_empty() {
        println!("Errors:");
        for error in &summary.errors {
            if error.index == 0 {
                println!("- {}", error.message);
            } else {
                match &error.story_id {
                    Some(story_id) => {
                        println!("- #{} [{}] {}", error.index, story_id, error.message)
                    }
                    None => println!("- #{} {}", error.index, error.message),
                }
            }
        }
    }

    Ok(())
}

fn import_mode_name(mode: ImportMode) -> &'static str {
    match mode {
        ImportMode::Create => "create",
        ImportMode::Update => "update",
        ImportMode::Upsert => "upsert",
    }
}

enum ImportOperation<'a> {
    Create,
    Update(&'a str),
}

enum ImportAction {
    Created(Option<String>),
    Updated(Option<String>),
}

fn parse_json_response<T>(response: Response) -> Result<T>
where
    T: DeserializeOwned,
{
    let status = response.status();
    let body = response
        .text()
        .context("failed to read HTTP response body")?;

    if status.is_success() {
        serde_json::from_str(&body).context("failed to parse JSON response")
    } else {
        bail!(render_error(status, &body));
    }
}

fn parse_empty_response(response: Response) -> Result<()> {
    let status = response.status();
    let body = response
        .text()
        .context("failed to read HTTP response body")?;

    if status.is_success() {
        Ok(())
    } else {
        bail!(render_error(status, &body));
    }
}

fn render_error(status: StatusCode, body: &str) -> String {
    match serde_json::from_str::<ErrorEnvelope>(body) {
        Ok(envelope) => format!("HTTP {status}: {}", envelope.error),
        Err(_err) if body.trim().is_empty() => format!("HTTP {status}"),
        Err(_err) => format!("HTTP {status}: {}", body.trim()),
    }
}

fn build_add_payload(args: &StoryAddArgs) -> Result<Value> {
    let mut payload = Map::new();

    let title = clean_non_empty(&args.title).context("--title is required")?;
    payload.insert("title".to_string(), Value::String(title));

    if let Some(value) = clean_optional(args.id.as_deref()) {
        payload.insert("id".to_string(), Value::String(value));
    }

    if let Some(value) = clean_optional(args.status.as_deref()) {
        payload.insert("status".to_string(), Value::String(value.to_lowercase()));
    }

    if let Some(value) = args.priority {
        payload.insert("priority".to_string(), json!(value));
    }

    if let Some(value) = clean_optional(args.description.as_deref()) {
        payload.insert("description".to_string(), Value::String(value));
    }

    if let Some(value) = clean_optional(args.notes.as_deref()) {
        payload.insert("notes".to_string(), Value::String(value));
    }

    if let Some(value) = clean_optional(args.testing_notes.as_deref()) {
        payload.insert("testingNotes".to_string(), Value::String(value));
    }

    let depends_on = normalize_list_values(&args.depends_on);
    if !depends_on.is_empty() {
        payload.insert("dependsOn".to_string(), json!(depends_on));
    }

    let acceptance = normalize_list_values(&args.acceptance);
    if !acceptance.is_empty() {
        payload.insert("acceptanceCriteria".to_string(), json!(acceptance));
    }

    Ok(Value::Object(payload))
}

fn build_edit_payload(args: &StoryEditArgs) -> Result<Value> {
    let mut payload = Map::new();

    if let Some(value) = clean_optional(args.title.as_deref()) {
        payload.insert("title".to_string(), Value::String(value));
    }

    if let Some(value) = clean_optional(args.status.as_deref()) {
        payload.insert("status".to_string(), Value::String(value.to_lowercase()));
    }

    if let Some(value) = args.priority {
        payload.insert("priority".to_string(), json!(value));
    }

    if let Some(value) = clean_optional(args.description.as_deref()) {
        payload.insert("description".to_string(), Value::String(value));
    }

    if let Some(value) = clean_optional(args.notes.as_deref()) {
        payload.insert("notes".to_string(), Value::String(value));
    }

    if let Some(value) = clean_optional(args.testing_notes.as_deref()) {
        payload.insert("testingNotes".to_string(), Value::String(value));
    }

    let depends_on = normalize_list_values(&args.depends_on);
    if !depends_on.is_empty() {
        payload.insert("dependsOn".to_string(), json!(depends_on));
    } else if args.clear_depends_on {
        payload.insert("dependsOn".to_string(), json!([]));
    }

    let acceptance = normalize_list_values(&args.acceptance);
    if !acceptance.is_empty() {
        payload.insert("acceptanceCriteria".to_string(), json!(acceptance));
    } else if args.clear_acceptance {
        payload.insert("acceptanceCriteria".to_string(), json!([]));
    }

    if payload.is_empty() {
        bail!(
            "no updates provided (set at least one field such as --title, --status, --priority, --testing-notes, --depends-on, or --acceptance)"
        );
    }

    Ok(Value::Object(payload))
}

fn print_story(action: &str, story: &Story, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(story).context("failed to render JSON output")?
        );
        return Ok(());
    }

    let story_id = fallback(&story.id, "(no-id)");
    let status = fallback(&story.status, "unknown");
    let title = fallback(&story.title, "(untitled)");

    println!("{action} story {story_id} [{status}] {title}");

    if !story.allowed_status_transitions.is_empty() {
        println!(
            "Allowed manual transitions: {}",
            story.allowed_status_transitions.join(", ")
        );
    }

    Ok(())
}

fn print_stories(stories: &[Story], as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(stories).context("failed to render JSON output")?
        );
        return Ok(());
    }

    if stories.is_empty() {
        println!("No stories found.");
        return Ok(());
    }

    let rows: Vec<(String, String, String, String)> = stories
        .iter()
        .map(|story| {
            (
                fallback(&story.id, "-").to_string(),
                fallback(&story.status, "-").to_string(),
                story
                    .priority
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "-".to_string()),
                fallback(&story.title, "-").to_string(),
            )
        })
        .collect();

    let id_w = rows.iter().map(|row| row.0.len()).max().unwrap_or(2).max(2);
    let status_w = rows.iter().map(|row| row.1.len()).max().unwrap_or(6).max(6);
    let pri_w = rows.iter().map(|row| row.2.len()).max().unwrap_or(3).max(3);

    println!(
        "{:<id_w$}  {:<status_w$}  {:>pri_w$}  {}",
        "ID",
        "Status",
        "Pri",
        "Title",
        id_w = id_w,
        status_w = status_w,
        pri_w = pri_w
    );

    for row in rows {
        println!(
            "{:<id_w$}  {:<status_w$}  {:>pri_w$}  {}",
            row.0,
            row.1,
            row.2,
            row.3,
            id_w = id_w,
            status_w = status_w,
            pri_w = pri_w
        );
    }

    Ok(())
}

fn print_resolved_project(project: &ResolvedProject, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(project).context("failed to render JSON output")?
        );
        return Ok(());
    }

    let slug = fallback(&project.slug, "(no-slug)");
    let name = fallback(&project.name, "(unnamed)");
    let provider = project.provider.as_deref().unwrap_or("unknown");

    println!("Resolved project {slug} [{provider}] {name}");

    if let Some(path) = project.local_path.as_deref() {
        if !path.trim().is_empty() {
            println!("local_path: {path}");
        }
    }

    if let Some(repository) = project.repository.as_deref() {
        if !repository.trim().is_empty() {
            println!("repository: {repository}");
        }
    }

    Ok(())
}

fn print_workflow_schema(schema: &WorkflowSchema, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(schema).context("failed to render JSON output")?
        );
        return Ok(());
    }

    let section_count = schema.sections.len();
    let required_sections = schema
        .workflow_front_matter
        .get("required_sections")
        .and_then(|value| value.as_array())
        .map(|values| {
            values
                .iter()
                .filter_map(|value| value.as_str().map(|item| item.to_string()))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    println!(
        "Workflow schema version {} ({} sections)",
        fallback(&schema.schema_version, "unknown"),
        section_count
    );

    if !required_sections.is_empty() {
        println!("Required sections: {}", required_sections.join(", "));
    }

    println!("Use --json for full machine-readable schema.");
    Ok(())
}

fn clean_non_empty(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn clean_optional(input: Option<&str>) -> Option<String> {
    input.and_then(clean_non_empty)
}

fn normalize_list_values(values: &[String]) -> Vec<String> {
    let mut unique = Vec::new();
    let mut seen = HashSet::new();

    for value in values {
        for piece in value.split(',') {
            let trimmed = piece.trim();
            if trimmed.is_empty() {
                continue;
            }

            let candidate = trimmed.to_string();
            if seen.insert(candidate.clone()) {
                unique.push(candidate);
            }
        }
    }

    unique
}

fn fallback<'a>(value: &'a str, default: &'a str) -> &'a str {
    if value.is_empty() {
        default
    } else {
        value
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_add_payload, build_edit_payload, normalize_list_values, parse_import_records,
        plan_delete_missing, print_workflow_schema, ImportMode, StoryAddArgs, StoryEditArgs,
        WorkflowSchema,
    };
    use serde_json::{Map, Value};

    #[test]
    fn parse_import_records_accepts_array_payload() {
        let input = r#"[{"id":"US-001","title":"A"},{"id":"US-002","title":"B"}]"#;
        let records = parse_import_records(input).expect("parse should succeed");

        assert_eq!(records.len(), 2);
        assert_eq!(
            records[0].get("id").and_then(|value| value.as_str()),
            Some("US-001")
        );
    }

    #[test]
    fn parse_import_records_accepts_wrapped_payload() {
        let input = r#"{"project":"kollywood","stories":[{"id":"US-010","title":"Story"}]}"#;
        let records = parse_import_records(input).expect("parse should succeed");

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].get("id").and_then(|value| value.as_str()),
            Some("US-010")
        );
    }

    #[test]
    fn parse_import_records_accepts_single_object() {
        let input = r#"{"id":"US-020","title":"Single"}"#;
        let records = parse_import_records(input).expect("parse should succeed");

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].get("id").and_then(|value| value.as_str()),
            Some("US-020")
        );
    }

    #[test]
    fn parse_import_records_rejects_invalid_payload() {
        let input = r#"{"stories":["bad"]}"#;
        let error = parse_import_records(input).expect_err("parse should fail");

        assert!(error
            .to_string()
            .contains("stories[0] must be a JSON object"));
    }

    #[test]
    fn plan_delete_missing_requires_ids() {
        let records = vec![Map::<String, Value>::new()];
        let error = plan_delete_missing(&records, ImportMode::Upsert).expect_err("must fail");

        assert!(error
            .to_string()
            .contains("--delete-missing requires id for every record"));
    }

    #[test]
    fn plan_delete_missing_rejects_create_mode() {
        let mut record = Map::<String, Value>::new();
        record.insert("id".to_string(), Value::String("US-001".to_string()));

        let error = plan_delete_missing(&[record], ImportMode::Create).expect_err("must fail");

        assert!(error
            .to_string()
            .contains("--delete-missing requires --mode update or --mode upsert"));
    }

    #[test]
    fn normalize_list_values_splits_commas_and_deduplicates() {
        let parsed = normalize_list_values(&[
            "US-001,US-002".to_string(),
            "US-002".to_string(),
            "  US-003  ".to_string(),
        ]);

        assert_eq!(parsed, vec!["US-001", "US-002", "US-003"]);
    }

    #[test]
    fn build_edit_payload_acceptance_values_win_over_clear_flag() {
        let args = StoryEditArgs {
            project: None,
            story_id: "US-001".to_string(),
            title: None,
            status: None,
            priority: None,
            description: None,
            notes: None,
            testing_notes: None,
            depends_on: Vec::new(),
            clear_depends_on: false,
            acceptance: vec!["criterion one, criterion two".to_string()],
            clear_acceptance: true,
            json: false,
        };

        let payload = build_edit_payload(&args).expect("payload should build");
        let object = payload.as_object().expect("payload must be an object");
        let acceptance = object
            .get("acceptanceCriteria")
            .and_then(Value::as_array)
            .expect("acceptanceCriteria should be present");

        assert_eq!(
            acceptance,
            &vec![
                Value::String("criterion one".to_string()),
                Value::String("criterion two".to_string())
            ]
        );
    }

    #[test]
    fn build_edit_payload_clear_acceptance_without_values_sets_empty_array() {
        let args = StoryEditArgs {
            project: None,
            story_id: "US-001".to_string(),
            title: None,
            status: None,
            priority: None,
            description: None,
            notes: None,
            testing_notes: None,
            depends_on: Vec::new(),
            clear_depends_on: false,
            acceptance: Vec::new(),
            clear_acceptance: true,
            json: false,
        };

        let payload = build_edit_payload(&args).expect("payload should build");
        let object = payload.as_object().expect("payload must be an object");

        assert_eq!(
            object.get("acceptanceCriteria"),
            Some(&Value::Array(Vec::new()))
        );
    }

    #[test]
    fn build_edit_payload_depends_on_values_win_over_clear_flag() {
        let args = StoryEditArgs {
            project: None,
            story_id: "US-001".to_string(),
            title: None,
            status: None,
            priority: None,
            description: None,
            notes: None,
            testing_notes: None,
            depends_on: vec!["US-010, US-011".to_string()],
            clear_depends_on: true,
            acceptance: Vec::new(),
            clear_acceptance: false,
            json: false,
        };

        let payload = build_edit_payload(&args).expect("payload should build");
        let object = payload.as_object().expect("payload must be an object");
        let depends_on = object
            .get("dependsOn")
            .and_then(Value::as_array)
            .expect("dependsOn should be present");

        assert_eq!(
            depends_on,
            &vec![
                Value::String("US-010".to_string()),
                Value::String("US-011".to_string())
            ]
        );
    }

    #[test]
    fn build_edit_payload_clear_depends_on_without_values_sets_empty_array() {
        let args = StoryEditArgs {
            project: None,
            story_id: "US-001".to_string(),
            title: None,
            status: None,
            priority: None,
            description: None,
            notes: None,
            testing_notes: None,
            depends_on: Vec::new(),
            clear_depends_on: true,
            acceptance: Vec::new(),
            clear_acceptance: false,
            json: false,
        };

        let payload = build_edit_payload(&args).expect("payload should build");
        let object = payload.as_object().expect("payload must be an object");

        assert_eq!(object.get("dependsOn"), Some(&Value::Array(Vec::new())));
    }

    #[test]
    fn build_add_payload_includes_testing_notes_when_provided() {
        let args = StoryAddArgs {
            project: None,
            title: "Story title".to_string(),
            id: None,
            status: None,
            priority: None,
            description: None,
            notes: None,
            testing_notes: Some("Only for tester".to_string()),
            depends_on: Vec::new(),
            acceptance: Vec::new(),
            json: false,
        };

        let payload = build_add_payload(&args).expect("payload should build");
        let object = payload.as_object().expect("payload must be an object");

        assert_eq!(
            object.get("testingNotes"),
            Some(&Value::String("Only for tester".to_string()))
        );
    }

    #[test]
    fn build_edit_payload_includes_testing_notes_when_provided() {
        let args = StoryEditArgs {
            project: None,
            story_id: "US-001".to_string(),
            title: None,
            status: None,
            priority: None,
            description: None,
            notes: None,
            testing_notes: Some("Retest checkout with promo code".to_string()),
            depends_on: Vec::new(),
            clear_depends_on: false,
            acceptance: Vec::new(),
            clear_acceptance: false,
            json: false,
        };

        let payload = build_edit_payload(&args).expect("payload should build");
        let object = payload.as_object().expect("payload must be an object");

        assert_eq!(
            object.get("testingNotes"),
            Some(&Value::String(
                "Retest checkout with promo code".to_string()
            ))
        );
    }

    #[test]
    fn print_workflow_schema_plain_text_succeeds() {
        let schema = WorkflowSchema {
            schema_version: "2026-04-06.1".to_string(),
            workflow_front_matter: serde_json::json!({
                "required_sections": ["agent", "workspace"]
            }),
            sections: {
                let mut map = Map::<String, Value>::new();
                map.insert("agent".to_string(), serde_json::json!({"required": true}));
                map.insert(
                    "workspace".to_string(),
                    serde_json::json!({"required": true}),
                );
                map
            },
        };

        print_workflow_schema(&schema, false).expect("should print plain schema summary");
    }
}
