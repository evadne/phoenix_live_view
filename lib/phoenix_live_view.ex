defmodule Phoenix.LiveView do
  @moduledoc """
  Live views are stateful views which update the browser on state changes.

  TODO
  - don't spawn extra process. Keep callbacks in channel
  - kill registry for now

  ## Configuration

  A `:signing_salt` configuration is required in your endpoint's
  `:live_view` configuration, for example:

      config :my_app, AppWeb.Endpoint,
        ...,
        live_view: [signing_salt: ...]

  You can generate a secure, random signing salt with the
  `mix phx.gen.secret 32` task.

  ## Life-cycle

  A live view begins as a regular HTTP request and HTML response,
  and then upgrades to a stateful view on client connect,
  guaranteeing a regular HTML page even if JavaScript is disabled.

  You begin by rendering a live view from the controller and providing
  *session* data to the view, which represents request information
  necessary for the view, such as params, cookie session info, etc.
  The session is signed and stored on the client, then provided back
  to the server when the client connects, or reconnects to the stateful
  view. When a view is rendered from the controller, the `mount/2` callback
  is invoked with the provided session data and the live view's socket.
  The `mount/2` callback wires up socket assigns necessary for rendering
  the view. After mounting, `render/1` is invoked and the HTML is sent
  as a regular HTML response to the client.

  After rendering the static page with a signed session, the live
  views connect from the client where stateful views are spawned
  to push rendered updates to the browser, and receive client events
  via phx bindings. Just like the controller flow, `mount/2` is invoked
  with the signed session, and socket state, where mount assigns
  values for rendering. However, in the connected client case, a
  live view process is spawned on the server, pushes the result of
  `render/1` to the client and contiues on for the duration of the
  connection. If at any point during the stateful life-cycle a
  crash is encountered, or the client connection drops, the client
  gracefully reconnects to the server, passing its signed session
  back to `mount/2`.

  ## Usage

  First, a live view requires two callbacks: `mount/2` and `render/1`:

      def AppWeb.ThermostatView do
        def render(assigns) do
          ~E\"""
          Current temperature: <%= @temperature %>
          \"""
        end

        def mount(%{id: id}, socket) do
          case Thermostat.get_reading(id) do
            {:ok, temperature} ->
              {:ok, assign(socket, :temperature, temperature)}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end

  The `render/1` callback receives the `socket.assigns` and is responsible
  for returning rendered content. You can use `Phoenix.HTML.sigil_E` to inline
  Phoenix HTML EEx templates.

  With a live view defined, you first call `live_render` from a controller:

      def show(conn, %{"id" => thermostat_id}) do
        Phoenix.LiveView.live_render(conn, AppWeb.ThermostatView, session: %{
          thermostat_id: id,
          current_user_id: get_session(conn, :user_id),
        })
      end

  As we've seen, you pass `:session` data about the request to the view,
  such as the current user's id in the cookie session, and parameters
  from the request. A regular HTML response is sent with a signed token
  embedded in the DOM.


  Next, your client code connects to the server:

      import LiveSocket from "live_view"

      let liveSocket = new LiveSocket("/live")
      liveSocket.connect()




  """

  @behaviour Plug

  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket

  @type unsigned_params :: map
  @type from :: binary

  @callback mount(Socket.session(), Socket.t()) :: {:ok, Socket.t()} | {:error, term}
  @callback render(Socket.assigns()) :: binary | list
  @callback terminate(
              reason :: :normal | :shutdown | {:shutdown, :left | :closed | term},
              Socket.t()
            ) :: term
  @callback handle_event(event :: binary, from, unsigned_params, Socket.t()) ::
              {:noreply, Socket.t()} | {:stop, reason :: term, Socket.t()}

  @optional_callbacks terminate: 2, mount: 2, handle_event: 4

  @doc """
  Renders a live view from an originating plug request or
  within a parent live view.

  ## Options

    * `:session` - the map of session data to sign and send
      to the client. When connecting from the client, the live view
      will receive the signed session from the client and verify
      the contents before proceeding with `mount/2`.

  ## Examples

      def AppWeb.ThermostatController do
        def show(conn, %{"id" => thermostat_id}) do
          live_render(conn, AppWeb.ThermostatView, session: %{
            thermostat_id: id,
            current_user_id: get_session(conn, :user_id),
          })
        end
      end

      def AppWeb.ThermostatView do
        def render(assigns) do
          ~E\"""
          Current temperature: <%= @temperatures %>
          <%= live_render(conn, AppWeb.ClockView) %>
          \"""
        end
      end

  """
  def live_render(conn_or_socket, view, opts \\ []) do
    session = opts[:session] || %{}
    do_live_render(conn_or_socket, view, session: session)
  end

  defp do_live_render(%Plug.Conn{} = conn, view, opts) do
    conn
    |> Plug.Conn.put_private(:phoenix_live_view, {view, opts})
    |> Phoenix.Controller.put_view(__MODULE__)
    |> Phoenix.Controller.render("template.html")
  end

  defp do_live_render(%Socket{} = parent, view, opts) do
    LiveView.Server.nested_static_render(parent, view, opts)
  end

  @doc """
  Returns true if the sockect is connected.

  Useful for checking the connectivity status when mounting the view.
  For example, on initial page render, the view is mounted statically,
  rendered, and the HTML is sent to the client. Once the client
  connects to the server, a live view is then spawned and mounted
  statefully within a process. Use `connected?/1` to conditionally
  perform stateful work, such as subscribing to pubsub topics,
  sending messages, etc.

  ## Examples

      defmodule DemoWeb.ClockView do
        use Phoenix.LiveView
        ...
        def mount(_session, socket) do
          if connected?(socket), do: :timer.send_interval(1000, self(), :tick)

          {:ok, assign(socket, date: :calendar.local_time())}
        end

        def handle_info(:tick, socket) do
          {:noreply, assign(socket, date: :calendar.local_time())}
        end
      end
  """
  def connected?(%Socket{} = socket), do: LiveView.Socket.connected?(socket)

  @doc """
  Adds key value pairs to socket assigns.

  A single key value pair may be passed, or a keyword list
  of assigns may be provided to be merged into existing
  socket assigns.

  ## Examples

      iex> assign(socket, :name, "Elixir")
      iex> assign(socket, name: "Elixir", logo: "💧")
  """
  def assign(%Socket{assigns: assigns} = socket, key, value) do
    %Socket{socket | assigns: Map.put(assigns, key, value)}
  end

  def assign(%Socket{assigns: assigns} = socket, attrs)
      when is_map(attrs) or is_list(attrs) do
    %Socket{socket | assigns: Enum.into(attrs, assigns)}
  end

  @doc """
  Updates an existing key in the socket assigns.

  The update function receives the current key's value and
  returns the updated value. Raises if the key does not exist.

  ## Examples

      iex> update(socket, :count, fn count -> count + 1 end)
      iex> update(socket, :count, &(&1 + 1))
  """
  def update(%Socket{assigns: assigns} = socket, key, func) do
    %Socket{socket | assigns: Map.update!(assigns, key, func)}
  end

  @doc """
  Adds a flash message to the socket to be displayed on redirect.

  ## Examples

      iex> put_flash(socket, :info, "It worked!")
      iex> put_flash(socket, :error, "You can't access that page")
  """
  def put_flash(%Socket{private: private} = socket, kind, msg) do
    new_private = Map.update(private, :flash, %{kind => msg}, &Map.put(&1, kind, msg))
    %Socket{socket | private: new_private}
  end

  @doc """
  Redirects the socket to a destination path.

  *Note*: liveview redirects rely on instructing client
  to perform a `window.location` update on the provided
  redirect location.

  TODO support `:external` and validation `:to` is a local path

  ## Options

    * `:to` - the path to redirect to
  """
  def redirect(%Socket{} = socket, opts) do
    {:stop, {:redirect, to: Keyword.fetch!(opts, :to), flash: flash(socket)}, socket}
  end

  defp flash(%Socket{private: %{flash: flash}}), do: flash
  defp flash(%Socket{}), do: nil

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__), except: [render: 2]
      # TODO don't import this, users can
      import Phoenix.HTML

      @behaviour unquote(__MODULE__)
      @impl unquote(__MODULE__)
      def mount(_session, socket), do: {:ok, socket}
      @impl unquote(__MODULE__)
      def terminate(reason, state), do: {:ok, state}
      defoverridable mount: 2, terminate: 2
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  # TODO kill the plugability for now in favor of user calling
  # in controller
  def call(conn, view) do
    live_render(conn, view, session: %{params: conn.path_params})
  end

  @doc false
  # Phoenix.LiveView acts as a view via put_view to maintain the
  # controller render + instrumentation stack
  def render("template.html", %{conn: conn}) do
    {root_view, opts} = conn.private.phoenix_live_view

    conn
    |> Phoenix.Controller.endpoint_module()
    |> LiveView.Server.static_render(root_view, opts)
  end
end
