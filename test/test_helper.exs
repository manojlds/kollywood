Code.require_file("support/conn_case.ex", __DIR__)

ExUnit.start()

unless Code.ensure_loaded?(KollywoodWeb.ConnCase) do
  Code.require_file("support/conn_case.ex", __DIR__)
end
