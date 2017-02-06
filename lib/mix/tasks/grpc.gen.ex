defmodule Mix.Tasks.Grpc.Gen do
  @moduledoc """
  Generate Elixir code from protobuf

  ## Examples

      mix grpc.gen priv/protos/helloworld.proto --out lib/

  The top level module name will be generated from package name by default,
  but you can custom it with `--namespace` option.

  ## Command line options

    * `--out` - Output path. Required
    * `--namespace Your.Service.Namespace` - Custom top level module name
    * `--use-package-names` - Use package names defined in protobuf definitions
    * `--use-proto-path` - Use proto path for protobuf parsing instead of
      copying content of proto to generated file, which is the default behavior.
      You should remember to generate Elixir files once .proto file changes,
      because proto will be loaded every time for this option.
  """
  use Mix.Task
  import Macro, only: [camelize: 1]
  import Mix.Generator
  alias GRPC.Proto

  @shortdoc "Generate Elixir code for Service and Stub from protobuf"
  @external_resource Path.expand("./templates/grpc.gen/grpc_service.ex", :code.priv_dir(:grpc))
  @tmpl_path "priv/templates/grpc.gen/grpc_service.ex"

  def run(args) do
    {opts, proto_paths, _} = OptionParser.parse(args)
    if opts[:out] do
      generate(proto_paths, opts[:out], opts)
    else
      Mix.raise "expected grpc.gen to receive the proto path and out path, " <>
        "got: #{inspect Enum.join(args, " ")}"
    end
  end

  defp generate(proto_paths, out_path, opts) do
    proto = parse_proto(proto_paths)
    [proto_path | _] = proto_paths
    assigns = [top_mod: top_mod(proto.package, proto_path, opts), proto_content: proto_content(proto_path, opts),
               proto: proto, proto_paths: proto_paths(proto_paths, out_path, opts),
               use_proto_path: opts[:use_proto_path], service_prefix: service_prefix(proto.package),
               use_package_names: opts[:use_package_names],
               compose_rpc: &__MODULE__.compose_rpc/2]
    create_file file_path(proto_path, out_path), grpc_gen_template(assigns)
    [:green, "You can generate a server template by: \n",
     :cyan, :bright, "mix grpc.gen.server #{proto_path} --out #{out_path}"]
    |> IO.ANSI.format
    |> IO.puts
  end

  def parse_proto(proto_paths) do
    import_dirs = Enum.map(proto_paths, &Path.dirname/1) |> Enum.uniq
    parsed = Protobuf.Parser.parse_files!(proto_paths, [imports: import_dirs, use_packages: true])
    proto = Enum.reduce parsed, %Proto{}, fn(item, proto) ->
      case {proto, item} do
        {%Proto{package: nil}, {:package, package}} ->
          %{proto | package: to_string(package)}
        {_, {{:service, service_name}, rpcs}} ->
          rpcs = Enum.map(rpcs, fn(rpc) -> Tuple.delete_at(rpc, 0) end)
          grpc_name = service_name |> to_string
          service_name = service_name |> to_string |> camelize
          service = %Proto.Service{name: service_name, grpc_name: grpc_name, rpcs: rpcs}
          %{proto | services: [service|proto.services]}
        _ -> proto
      end
    end
    %{proto | services: Enum.reverse(proto.services)}
  end

  def top_mod(package, proto_path, opts) do
    package = opts[:namespace] || package || Path.basename(proto_path, ".proto")
    package
    |> to_string
    |> String.split(".")
    |> Enum.map(fn(seg)-> camelize(seg) end)
    |> Enum.join(".")
  end

  defp service_prefix(package)  do
    if package && String.length(package) > 0, do: package <> ".", else: ""
  end

  defp proto_paths(proto_paths, out_path, opts) do
    if opts[:use_proto_path] do
      proto_paths |> Enum.map(fn proto_path ->
        proto_path = Path.relative_to_cwd(proto_path)
        level = out_path |> Path.relative_to_cwd |> Path.split |> length
        prefix = List.duplicate("..", level) |> Enum.join("/")
        Path.join(prefix, proto_path)
      end)
    else
      []
    end
  end

  defp proto_content(proto_path, opts) do
    if opts[:use_proto_path] do
      ""
    else
      File.read!(proto_path)
    end
  end

  # Helper in EEx
  @doc false
  def compose_rpc({name, request, reply, req_stream, rep_stream, _}, top_mod) do
    request = "#{top_mod}.#{format_type(request)}"
    request = if req_stream, do: "stream(#{format_type(request)})", else: request
    reply = "#{top_mod}.#{format_type(reply)}"
    reply = if rep_stream, do: "stream(#{format_type(reply)})", else: reply
    "rpc #{inspect name}, #{request}, #{reply}"
  end

  def format_type(type) do
    type
    |> to_string
    |> String.split(".")
    |> Enum.map(fn(seg)-> camelize(seg) end)
    |> Enum.join(".")
  end

  defp file_path(proto_path, out_path) do
    name = Path.basename(proto_path, ".proto")
    File.mkdir_p(out_path)
    Path.join(out_path, name <> ".pb.ex")
  end

  defp grpc_gen_template(binding) do
    tmpl_path = Application.app_dir(:grpc, @tmpl_path)
    EEx.eval_file(tmpl_path, binding, trim: true)
  end
end
