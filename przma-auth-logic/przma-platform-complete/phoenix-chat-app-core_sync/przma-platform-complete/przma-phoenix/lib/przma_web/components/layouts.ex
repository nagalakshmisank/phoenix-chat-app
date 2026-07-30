defmodule PRZMAWeb.Layouts do
  @moduledoc """
  Root HTML shell for the API console. Loads Phoenix + Phoenix LiveView
  straight from a CDN so we don't need an esbuild/tailwind asset pipeline
  just for this dev tool.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>PRZMA API Console</title>
        <script defer src="https://cdn.jsdelivr.net/npm/phoenix@1.7/priv/static/phoenix.min.js">
        </script>
        <script defer src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20/priv/static/phoenix_live_view.min.js">
        </script>
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0;
            font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
            background: #0f1115;
            color: #e6e6e6;
          }
          a { color: inherit; }
          button {
            cursor: pointer;
            font-family: inherit;
          }
          input, textarea, select {
            font-family: "SFMono-Regular", Consolas, Menlo, monospace;
            background: #1a1d24;
            color: #e6e6e6;
            border: 1px solid #33363f;
            border-radius: 6px;
            padding: 8px;
          }
        </style>
      </head>
      <body>
        {@inner_content}
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            params: {_csrf_token: csrfToken}
          });
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end
end
