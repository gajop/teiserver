defmodule TeiserverWeb.Account.SecurityController do
  use CentralWeb, :controller

  alias Teiserver.Account
  alias Teiserver.Account.UserLib

  plug(:add_breadcrumb, name: 'Teiserver', url: '/teiserver')
  plug(:add_breadcrumb, name: 'Account', url: '/teiserver/account')
  plug(:add_breadcrumb, name: 'Security', url: '/teiserver/account/security')

  plug(AssignPlug,
    site_menu_active: "teiserver_account",
    sub_menu_active: "account"
  )

  @spec index(Plug.Conn.t(), map) :: Plug.Conn.t()
  def index(conn, _params) do
    user_tokens = Account.list_user_tokens(
      search: [
        user_id: conn.user_id
      ],
      order_by: "Most recently used"
    )

    conn
    |> assign(:user_tokens, user_tokens)
    |> render("index.html")
  end

  @spec edit_password(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def edit_password(conn, _params) do
    user = Account.get_user!(conn.user_id)
    changeset = Account.change_user(user)

    conn
    |> add_breadcrumb(name: "Password", url: conn.request_path)
    |> assign(:changeset, changeset)
    |> assign(:user, user)
    |> render("edit_password.html")
  end

  @spec update_password(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_password(conn, %{"user" => user_params}) do
    user = Account.get_user!(conn.user_id)

    case Central.Account.update_user(user, user_params, :password) do
      {:ok, _user} ->
        # User password updated
        Teiserver.User.set_new_spring_password(user.id, user_params["password"])

        conn
        |> put_flash(:info, "Account password updated successfully.")
        |> redirect(to: Routes.ts_account_security_path(conn, :index))

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit_password.html", user: user, changeset: changeset)
    end
  end

  @spec delete_token(Plug.Conn.t(), Map.t()) :: Plug.Conn.t()
  def delete_token(conn, %{"id" => id}) do
    token =
      Account.get_user_token(id,
        search: [
          user_id: conn.user_id
        ]
      )

    {:ok, _code} = Account.delete_user_token(token)

    conn
    |> put_flash(:info, "Token deleted successfully.")
    |> redirect(to: Routes.ts_account_security_path(conn, :index))
  end
end
