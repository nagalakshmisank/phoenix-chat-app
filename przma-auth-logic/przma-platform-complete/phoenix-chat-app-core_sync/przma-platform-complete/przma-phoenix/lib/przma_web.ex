defmodule PRZMAWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, views, channels and so on.

  This can be used in your application as:

      use PRZMAWeb, :controller
      use PRZMAWeb, :view
      use PRZMAWeb, :channel

  The definitions below will be executed for every view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below as many of them are meant to be overridden by
  generators and you would lose them.
  """

  def controller do
    quote do
      use Phoenix.Controller, namespace: PRZMAWeb

      import Plug.Conn
      import PRZMAWeb.Gettext
      alias PRZMAWeb.Router.Helpers, as: Routes
    end
  end

  def view do
    quote do
      use Phoenix.View,
        root: "lib/przma_web/templates",
        namespace: PRZMAWeb

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_flash: 1, get_flash: 2, view_module: 1]

      import PRZMAWeb.ErrorHelpers
      import PRZMAWeb.Gettext
      alias PRZMAWeb.Router.Helpers, as: Routes
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      import PRZMAWeb.Gettext
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: false
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
      # added: required for the `live` / `live_session` macros in router.ex
      import Phoenix.LiveView.Router
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end