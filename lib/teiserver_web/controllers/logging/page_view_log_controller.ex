defmodule TeiserverWeb.Logging.PageViewLogController do
  use CentralWeb, :controller

  alias Teiserver.Logging
  alias Central.Account.GroupLib
  alias Central.Helpers.TimexHelper
  import Central.Helpers.StringHelper, only: [get_hash_id: 1]

  plug :add_breadcrumb, name: 'Logging', url: '/logging'
  plug :add_breadcrumb, name: 'Page views', url: '/logging/page_views'

  plug(AssignPlug,
    site_menu_active: "central_logging",
    sub_menu_active: "page_view"
  )

  plug Bodyguard.Plug.Authorize,
    policy: Teiserver.Logging.PageViewLog,
    action: {Phoenix.Controller, :action_name},
    user: {Central.Account.AuthLib, :current_user}

  @spec index(Plug.Conn.t(), Map.t()) :: Plug.Conn.t()
  def index(conn, params) do
    page_view_logs =
      Logging.list_page_view_logs(
        search: [
          user_id: params["user_id"]
        ],
        joins: [:user],
        order: "Newest first",
        limit: 50
      )

    conn
    |> assign(:page_view_logs, page_view_logs)
    |> assign(:show_search, Map.has_key?(params, "search"))
    |> assign(:params, form_params())
    |> search_dropdowns
    |> assign(:quick_search, Map.get(params, "s", ""))
    |> render("index.html")
  end

  @spec search(Plug.Conn.t(), Map.t()) :: Plug.Conn.t()
  def search(conn, %{"search" => params}) do
    params = form_params(params)

    page_view_logs =
      Logging.list_page_view_logs(
        search: [
          user_id: params["user_id"],
          start_date: TimexHelper.parse_time_input(params["start_date"]),
          end_date: TimexHelper.parse_time_input(params["end_date"]),
          path: params["path"],
          section: params["section"]
        ],
        joins: [:user],
        order: params["order"],
        limit: params["limit"]
      )

    conn
    |> assign(:params, params)
    |> assign(:page_view_logs, page_view_logs)
    |> assign(:show_search, "hidden")
    |> search_dropdowns
    |> render("index.html")
  end

  @spec show(Plug.Conn.t(), Map.t()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    page_view_log = Logging.get_page_view_log!(id, joins: [:user])

    render(conn, "show.html", page_view_log: page_view_log)
  end

  @spec delete(Plug.Conn.t(), Map.t()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    page_view_log = Logging.get_page_view_log!(id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Logging.delete_page_view_log(page_view_log)

    conn
    |> put_flash(:info, "Page view log deleted successfully.")
    |> redirect(to: Routes.logging_page_view_log_path(conn, :index))
  end

  @spec form_params(Map.t()) :: Map.t()
  defp form_params(params \\ %{}) do
    %{
      "section" => Map.get(params, "section", "any"),
      "path" => Map.get(params, "path", ""),
      "admin_group_id" => Map.get(params, "admin_group_id", ""),
      "order" => Map.get(params, "order", "Newest first"),
      "limit" => Map.get(params, "limit", "50"),
      "user_id" => Map.get(params, "account_user", "") |> get_hash_id,
      "account_user" => Map.get(params, "account_user", ""),
      "start_date" => Map.get(params, "start_date", ""),
      "end_date" => Map.get(params, "end_date", "")
    }
  end

  @spec search_dropdowns(Plag.Conn.t()) :: Plug.Conn.t()
  def search_dropdowns(conn) do
    conn
    |> assign(:groups, GroupLib.dropdown(conn))
  end
end
