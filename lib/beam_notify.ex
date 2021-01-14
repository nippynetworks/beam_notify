defmodule BEAMNotify do
  use GenServer
  require Logger

  @moduledoc """
  Send a message to the BEAM from a shell script


  """

  @typedoc """
  Callback for dispatching notifications

  BEAMNotify calls the dispatcher function whenever a message comes in. The
  first parameter is the list of arguments passed to `$BEAM_NOTIFY`. The
  second argument is a map containing environment variables. Whether or
  not the map is populated depends on the options to `start_link/1`.
  """
  @type dispatcher() :: ([String.t()], %{String.t() => String.t()} -> :ok)

  @typedoc """
  BEAMNotify takes the following options

  * `:name` - a unique name for this notifier. This is required if you expect
    to run multiple BEAMNotify GenServers at a time.
  * `:dispatcher` - a function to call when a notification comes in
  * `:environment` - TBD
  * `:recbuf` - receive buffer size. If you're sending a particular large
     amount of data and getting errors from `:erlang.binary_to_term(data)`, try
     making this bigger. Defaults to 8192.
  """
  @type options() :: [name: binary() | atom(), dispatcher: dispatcher()]

  @doc """
  Start the BEAMNotify message receiver
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(options) do
    name = gen_server_name(options[:name])
    GenServer.start_link(__MODULE__, options, name: name)
  end

  defp gen_server_name(nil) do
    gen_server_name(:global)
  end

  defp gen_server_name(name) do
    Module.concat(__MODULE__, name)
  end

  @doc """
  Return the OS environment needed to call `$BEAM_NOTIFY`

  This returns a map that can be passed directly to `System.cmd/3` via its
  `:env` option. Call it with either the `BEAMNotify` GenServer's pid or the
  name that was used to start the Genserver.
  """
  @spec env(pid() | binary() | atom()) :: Enumerable.t()
  def env(pid) when is_pid(pid) do
    GenServer.call(pid, :env)
  end

  def env(name) when is_binary(name) or is_atom(name) do
    GenServer.call(gen_server_name(name), :env)
  end

  @impl GenServer
  def init(options) do
    socket_path = Path.join(System.tmp_dir!(), "beam_notify-#{options[:name]}")
    bin_path = Application.app_dir(:beam_notify, ["priv", "beam_notify"])
    dispatcher = Keyword.get(options, :dispatcher, &null_dispatcher/2)
    recbuf = Keyword.get(options, :recbuf, 8192)

    # Blindly try to remove an old file just in case it exists from a previous run
    _ = File.rm(socket_path)
    _ = File.mkdir_p(Path.dirname(socket_path))

    {:ok, socket} =
      :gen_udp.open(0, [
        :local,
        :binary,
        {:active, true},
        {:ip, {:local, socket_path}},
        {:recbuf, recbuf}
      ])

    state = %{
      socket_path: socket_path,
      socket: socket,
      bin_path: bin_path,
      dispatcher: dispatcher
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:env, _from, state) do
    env = %{"BEAM_NOTIFY" => state.bin_path, "BEAM_NOTIFY_OPTIONS" => state.socket_path}
    {:reply, env, state}
  end

  @impl GenServer
  def handle_info({:udp, socket, _, 0, data}, %{socket: socket} = state) do
    {args, env} = :erlang.binary_to_term(data)

    state.dispatcher.(args, env)

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Try to clean up
    _ = File.rm(state.socket_path)
  end

  defp null_dispatcher(args, env) do
    Logger.warn("beam_notify called with no dispatcher: #{inspect(args)}, #{inspect(env)}")
  end
end
