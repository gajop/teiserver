defmodule TeiserverWeb.Account.PartyLive.Show do
  use TeiserverWeb, :live_view
  alias Phoenix.PubSub
  require Logger

  alias Teiserver.{Account, Battle}
  alias Teiserver.Account.PartyLib
  import Central.Helpers.StringHelper, only: [possessive: 1]
  import Central.Helpers.NumberHelper, only: [int_parse: 1]

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
        |> AuthPlug.live_call(session)
        |> TSAuthPlug.live_call(session)
        |> NotificationPlug.live_call()

    client = Account.get_client_by_id(socket.assigns.user_id)
    lobby_user_ids = if client != nil and client.lobby_id != nil do
      :ok = PubSub.subscribe(Central.PubSub, "teiserver_lobby_updates:#{client.lobby_id}")
      Battle.get_lobby_member_list(client.lobby_id)
    else
      []
    end

    user = Account.get_user_by_id(socket.assigns.user_id)

    :ok = PubSub.subscribe(Central.PubSub, "teiserver_client_messages:#{socket.assigns.user_id}")
    :ok = PubSub.subscribe(Central.PubSub, "teiserver_liveview_client:#{socket.assigns.user_id}")

    socket = socket
      |> add_breadcrumb(name: "Teiserver", url: "/teiserver")
      |> add_breadcrumb(name: "Parties", url: "/teiserver/account/parties")
      |> assign(:lobby_user_ids, lobby_user_ids)
      |> assign(:client, client)
      |> assign(:user, user)
      |> assign(:party, nil)
      |> build_user_lookup

    {:ok, socket}
  end

  @impl true
  def handle_params(_, _, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, socket |> redirect(to: Routes.general_page_path(socket, :index))}
  end

  def handle_params(%{"id" => party_id}, _, socket) do
    party = Account.get_party(party_id)
    if party do
      if Enum.member?(party.members, socket.assigns.user_id) or allow?(socket, "teiserver.staff.moderator") do
        leader_name = Account.get_username(party.leader)
        :ok = PubSub.subscribe(Central.PubSub, "teiserver_party:#{party_id}")

        {:noreply,
          socket
            |> add_breadcrumb(name: "#{leader_name |> possessive} party", url: "/teiserver/account/parties")
            |> assign(:site_menu_active, "parties")
            |> assign(:menu_override, Routes.ts_general_general_path(socket, :index))
            |> assign(:view_colour, PartyLib.colours())
            |> assign(:user_lookup, %{})
            |> assign(:party_id, party_id)
            |> assign(:party, party)
            |> build_user_lookup
        }
      else
        {:noreply, socket |> redirect(to: Routes.ts_game_party_index_path(socket, :index))}
      end
    else
      {:noreply, socket |> redirect(to: Routes.ts_game_party_index_path(socket, :index))}
    end
  end

  @impl true
  def render(assigns) do
    Phoenix.View.render(TeiserverWeb.Account.PartyLiveView, "show.html", assigns)
  end

  @impl true
  def handle_info(%{channel: "teiserver_party:" <> _, event: :closed}, socket) do
    {:noreply, socket |> redirect(to: Routes.ts_game_party_index_path(socket, :index))}
  end

  def handle_info(data = %{channel: "teiserver_party:" <> _, event: :updated_values}, socket) do
    new_party = socket.assigns.party
      |> Map.merge(data.new_values)

    {:noreply,
      socket
        |> assign(:party, new_party)
        |> build_user_lookup
    }
  end

  def handle_info(data = %{channel: "teiserver_liveview_client:" <> _}, socket) do
    socket = case data.event do
      :joined_lobby ->
        :ok = PubSub.subscribe(Central.PubSub, "teiserver_lobby_updates:#{data.lobby_id}")
        lobby_user_ids = Battle.get_lobby_member_list(data.lobby_id)

        socket
          |> assign(:lobby_user_ids, lobby_user_ids)
          |> build_user_lookup

      :left_lobby ->
        :ok = PubSub.unsubscribe(Central.PubSub, "teiserver_lobby_updates:#{data.lobby_id}")
        socket
          |> assign(:lobby_user_ids, [])

      _ ->
        socket
    end

    {:noreply, socket}
  end

  def handle_info(%{channel: "teiserver_party:" <> _}, socket) do
    {:noreply, socket}
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _, event: :connected}, socket) do
    {:noreply,
      socket
        |> assign(:client, Account.get_client_by_id(socket.assigns.user_id))
    }
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _, event: :disconnected}, socket) do
    {:noreply,
      socket
        |> assign(:client, nil)
    }
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _}, socket) do
    {:noreply, socket}
  end

  def handle_info({:lobby_update, :add_user, _lobby_id, userid}, socket) do
    extra_ids = [userid | socket.assigns.lobby_user_ids]

    {:noreply,
      socket
        |> assign(:lobby_user_ids, extra_ids)
        |> build_user_lookup
    }
  end

  def handle_info({:lobby_update, :remove_user, _lobby_id, userid}, socket) do
    extra_ids = List.delete(socket.assigns.lobby_user_ids, userid)

    {:noreply,
      socket
        |> assign(:lobby_user_ids, extra_ids)
        |> build_user_lookup
    }
  end

  def handle_info({:lobby_update, _, _, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("create_invite", %{"userid" => userid_str}, socket) do
      userid = int_parse(userid_str)
      Account.create_party_invite(socket.assigns.party_id, userid)
    {:noreply, socket}
  end

  def handle_event("cancel_invite", %{"userid" => userid_str}, socket) do
    if leader?(socket) do
      userid = int_parse(userid_str)
      Account.cancel_party_invite(socket.assigns.party_id, userid)
    end
    {:noreply, socket}
  end

  def handle_event("kick", %{"userid" => userid_str}, socket) do
    if leader?(socket) do
      userid = int_parse(userid_str)
      Account.move_client_to_party(userid, nil)
      Account.kick_user_from_party(socket.assigns.party_id, userid)
    end
    {:noreply, socket}
  end

  # We kick the user to ensure any connected clients will also update, leaving is normally done
  # by the connected tachyon client
  def handle_event("leave", _, socket) do
    Account.move_client_to_party(socket.assigns.user_id, nil)
    Account.leave_party(socket.assigns.party_id, socket.assigns.user_id)
    {:noreply, socket |> redirect(to: Routes.ts_game_party_index_path(socket, :index))}
  end

  @spec build_user_lookup(map) :: map
  defp build_user_lookup(%{assigns: %{party: nil}} = socket) do
    socket
      |> assign(:user_lookup, %{})
  end
  defp build_user_lookup(socket) do
    existing_user_ids = Map.keys(socket.assigns[:user_lookup] || %{})

    ids = [
      socket.assigns.party.members,
      socket.assigns.party.pending_invites,
      socket.assigns.user.friends,
      socket.assigns.lobby_user_ids
    ]
      |> List.flatten
      |> Enum.uniq

    new_users = ids
      |> Enum.reject(fn m -> Enum.member?(existing_user_ids, m) end)
      |> Enum.filter(fn userid -> Account.client_exists?(userid) end)
      |> Account.list_users_from_cache
      |> Map.new(fn u -> {u.id, u} end)

    new_user_lookup = Map.merge(socket.assigns.user_lookup, new_users)

    socket
      |> assign(:user_lookup, new_user_lookup)
  end

  @spec leader?(map()) :: boolean
  defp leader?(socket = %{assigns: %{user_id: user_id, party: %{leader: leader_id}}}) do
    moderator = allow?(socket, "teiserver.staff.moderator")
    moderator or (leader_id == user_id)
  end
end
