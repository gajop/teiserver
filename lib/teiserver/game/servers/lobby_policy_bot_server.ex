defmodule Teiserver.Game.LobbyPolicyBotServer do
  @moduledoc """
  The LobbyPolicyBots are the accounts present in each managed lobby and involved in managing that lobby specifically
  """

  alias Phoenix.PubSub
  alias Teiserver.{Game, User, Client, Battle, Account, Coordinator}
  alias Teiserver.Battle.{Lobby, LobbyChat}
  import Central.Helpers.NumberHelper, only: [int_parse: 1]
  alias Teiserver.Data.Types, as: T
  use GenServer
  require Logger

  @tick_interval 10_000

  @impl true
  def handle_info(
    %{channel: "lobby_policy_internal:" <> _, event: :request_status_update},
    %{lobby_id: nil} = state
  ) do
    :ok = Game.cast_lobby_organiser(state.lobby_policy.id, %{
      event: :bot_status_update,
      name: state.user.name,
      status: %{
        userid: state.userid,
        lobby_id: nil
      }
    })

    {:noreply, state}
  end

  def handle_info(
    %{channel: "lobby_policy_internal:" <> _, event: :request_status_update},
    %{lobby_id: lobby_id} = state
  ) do
    lobby = Battle.get_lobby(lobby_id)

    :ok = if lobby do
      Game.cast_lobby_organiser(state.lobby_policy.id, %{
        event: :bot_status_update,
        name: state.user.name,
        status: %{
          userid: state.userid,
          lobby_id: state.lobby_id,
          in_progress: lobby.in_progress,
          member_count: Enum.count(lobby.members)
        }
      })
    else
      Game.cast_lobby_organiser(state.lobby_policy.id, %{
      event: :bot_status_update,
      name: state.user.name,
      status: %{
        userid: state.userid,
        lobby_id: state.lobby_id,
        in_progress: false,
        member_count: -1
      }
    })
    end

    {:noreply, state}
  end

  def handle_info(%{channel: "lobby_policy_internal:" <> _, event: :disconnect}, state) do
    Client.disconnect(state.userid, "Bot disconnect")
    {:noreply, state}
  end

  def handle_info(%{channel: "lobby_policy_internal:" <> _, event: :updated_policy} = m, state) do
    {:noreply, %{state | lobby_policy: m.new_lobby_policy}}
  end

  def handle_info(%{channel: "lobby_policy_internal:" <> _}, state) do
    {:noreply, state}
  end

  # teiserver_client_messages
  def handle_info(%{channel: "teiserver_client_messages:" <> _, event: :disconnected}, state) do
    # We've disconnected, time to kill this process
    DynamicSupervisor.terminate_child(Teiserver.LobbyPolicySupervisor, self())
    {:noreply, state}
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _, event: :added_to_lobby, lobby_id: lobby_id}, state) do
    PubSub.unsubscribe(Central.PubSub, "teiserver_lobby_updates:#{lobby_id}")
    PubSub.unsubscribe(Central.PubSub, "teiserver_lobby_chat:#{lobby_id}")

    PubSub.subscribe(Central.PubSub, "teiserver_lobby_updates:#{lobby_id}")
    PubSub.subscribe(Central.PubSub, "teiserver_lobby_chat:#{lobby_id}")

    lobby = Battle.get_lobby(lobby_id)
    new_state = %{state |
      lobby_id: lobby_id,
      founder_id: lobby.founder_id
    }

    lobby_name = generate_lobby_name(state)
    send_chat(new_state, "$rename #{lobby_name}")

    pick_random_map(new_state)

    # TODO: set lobby.lobby_policy to my id

    {:noreply, new_state}
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _, event: :client_updated}, state) do
    {:noreply, state}
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _, event: :force_join_lobby}, state) do
    {:noreply, state}
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _, event: :received_direct_message} = e, state) do
    userid = e.sender_id
    content = e.message_content |> Enum.join("") |> String.trim()

    if content == "$settings" do
      send_dm(state, userid, "My maplist is: #{state.lobby_policy.map_list |> Enum.join(", ")}")
    end

    {:noreply, state}
  end

  def handle_info(%{channel: "teiserver_client_messages:" <> _} = _m, state) do
    # Logger.error("Error at: #{__ENV__.file}:#{__ENV__.line}\n#{inspect m.event}")
    {:noreply, state}
  end

  # No lobby, need to find one!
  def handle_info(:tick, %{lobby_id: nil} = state) do
    # TODO: Use the coordinator to request a new lobby be hosted by SPADS
    empty_lobby = Lobby.find_empty_lobby(fn l ->
      (
        String.starts_with?(l.name, "EU - ") or
        # String.starts_with?(l.name, "EU - 1") or
        # String.starts_with?(l.name, "EU - 3") or
        String.starts_with?(l.name, "US ") or
        String.starts_with?(l.name, "BH ")
      )
      and
        l.password == nil
      and
        l.in_progress == false
    end)

    case empty_lobby do
      nil ->
        Logger.info("LobbyPolicyBotServer find_empty_lobby was unable to find an empty lobby")
        {:noreply, state}

      _ ->
        Lobby.force_add_user_to_lobby(state.userid, empty_lobby.id)

        Logger.info("LobbyPolicyBotServer found an empty lobby")
        {:noreply, %{state | lobby_id: empty_lobby.id}}
    end
  end

  def handle_info(:tick, state) do
    lobby = Battle.get_lobby(state.lobby_id)
    correct_lobby_name = generate_lobby_name(state)

    new_state = cond do
      lobby == nil ->
        leave_lobby(state)

      lobby.name != correct_lobby_name ->
        Logger.error("Found name: '#{lobby.name}', Generated: '#{correct_lobby_name}'")
        send_chat(state, "$rename #{correct_lobby_name}")
        state

      true ->
        check_consul_state(state)

        client = state.userid
          |> Account.get_client_by_id()
          |> Map.merge(%{sync: %{
            bot: 1,
            game: 1,
            engine: 1,
            map: 1
          }})

        Account.replace_update_client(client, :client_updated_battlestatus)

        state
    end

    {:noreply, new_state}
  end

  # Lobby updates
  def handle_info({:lobby_update, :add_user, _lobby_id, userid}, state) do
    generate_welcome_message(state)
    |> Enum.each(fn line ->
      User.send_direct_message(state.userid, userid, line)
    end)
    {:noreply, state}
  end

  def handle_info({:lobby_update, _action, _lobby_id, _data}, state) do
    # IO.inspect {action, data}, label: "lobby_update"
    {:noreply, state}
  end

  # Lobby chat
  def handle_info(%{channel: "teiserver_lobby_chat:" <> _, userid: userid, message: message}, state) do
    new_state = cond do
      userid == state.founder_id ->
        handle_founder_chat(message, state)

      userid == state.userid ->
        state

      true ->
        handle_user_chat(userid, message, state)
    end
    {:noreply, new_state}
  end

  def handle_info({:force_join_battle, _, _}, state) do
    {:noreply, state}
  end

  defp check_consul_state(%{lobby_policy: lp} = state) do
    consul_state = Coordinator.call_consul(state.lobby_id, :get_consul_state)

    expected_map = %{
      minimum_rating_to_play: lp.min_rating || 0,
      maximum_rating_to_play: lp.max_rating || 1000,
      minimum_uncertainty_to_play: lp.min_uncertainty || 0,
      maximum_uncertainty_to_play: lp.max_uncertainty || 1000,
      minimum_rank_to_play: lp.min_rank || 0,
      maximum_rank_to_play: lp.max_rank || 1000,
      welcome_message: nil
    }

    found_map = (consul_state || %{})
      |> Map.take(Map.keys(expected_map))

    if expected_map != found_map do
      send_chat(state, "Incorrect settings detected, correcting.")
      Coordinator.send_consul(state.lobby_id, {:merge, expected_map})
    end
  end

  @spec handle_user_chat(T.userid(), String.t(), map()) :: map()
  defp handle_user_chat(userid, "!boss" <> rem, state) do
    if String.trim(rem) != "" do
      LobbyChat.say(userid, "!ev", state.lobby_id)
      Lobby.kick_user_from_battle(userid, state.lobby_id)
    end
    state
  end

  defp handle_user_chat(userid, "!preset" <> rem, state) do
    if String.trim(rem) != state.lobby_policy.preset do
      LobbyChat.say(userid, "!ev", state.lobby_id)
    end
    state
  end

  defp handle_user_chat(_userid, _message, state) do
    # Logger.error("handle_user_chat - #{userid} - #{message}")
    state
  end

  @spec handle_founder_chat(String.t(), map()) :: map()
  defp handle_founder_chat("* BarManager|" <> json_str, state) do
    case Jason.decode(json_str) do
      {:ok, %{"BattleStateChanged" => new_status}} ->
        if new_status["locked"] != "unlocked" do
          send_chat(state, "Room cannot be locked, unlocking")
          send_to_founder(state, "!unlock")
        end

        if new_status["preset"] != state.lobby_policy.preset do
          send_chat(state, "Preset must be #{state.lobby_policy.preset}, re-setting it")
          send_to_founder(state, "!preset #{state.lobby_policy.preset}")
          pick_random_map(state)
        end

        team_count = new_status["nbTeams"] |> int_parse
        cond do
          team_count > state.lobby_policy.max_teamcount ->
            send_chat(state, "Max team count is #{state.lobby_policy.max_teamcount}, re-setting it")
            send_to_founder(state, "!set teamcount #{state.lobby_policy.max_teamcount}")

          true ->
            :ok
        end

        team_size = new_status["teamSize"] |> int_parse
        cond do
          team_size > state.lobby_policy.max_teamsize ->
            send_chat(state, "Max team size is #{state.lobby_policy.max_teamsize}, re-setting it")
            send_to_founder(state, "!set teamsize #{state.lobby_policy.max_teamsize}")

          team_size < state.lobby_policy.min_teamsize ->
            send_chat(state, "Min team size is #{state.lobby_policy.min_teamsize}, re-setting it")
            send_to_founder(state, "!set teamsize #{state.lobby_policy.min_teamsize}")

          true ->
            :ok
        end

      {:ok, _json} ->
        # Logger.error("BarManager unknown json object - #{json_str}\n#{inspect err}")
        :ok

      err ->
        Logger.error("BarManager bad json - #{json_str}\n#{inspect err}")
        :ok
    end
    state
  end

  defp handle_founder_chat("* Map changed by " <> user_and_map, state) do
    [_user | map_parts] = user_and_map
      |> String.split(" ")

    current_map = Enum.join(map_parts, " ")

    if not is_map_allowed?(current_map, state) do
      pick_random_map(state)
    end

    state
  end

  defp handle_founder_chat("* Automatic random map rotation: next map is" <> map_and_quotes, state) do
    current_map = map_and_quotes
      |> String.replace("\"", "")
      |> String.trim()

    if not is_map_allowed?(current_map, state) do
      pick_random_map(state)
    end

    state
  end

  defp handle_founder_chat("* Boss mode enabled for " <> _boss_name, state) do
    send_to_founder(state, "!boss")
    state
  end

  defp handle_founder_chat(_, state) do
    state
  end

  defp send_chat(state, msg) do
    LobbyChat.say(state.userid, msg, state.lobby_id)
  end

  defp send_dm(state, userid, msg) do
    User.send_direct_message(state.userid, userid, msg)
  end

  defp send_to_founder(state, msg) do
    User.send_direct_message(state.userid, state.founder_id, msg)
  end

  @spec leave_lobby(map()) :: map()
  defp leave_lobby(%{lobby_id: nil} = state), do: state
  defp leave_lobby(state) do
    PubSub.unsubscribe(Central.PubSub, "teiserver_lobby_updates:#{state.lobby_id}")
    PubSub.unsubscribe(Central.PubSub, "teiserver_lobby_chat:#{state.lobby_id}")

    Lobby.remove_user_from_battle(state.userid, state.lobby_id)

    %{state | lobby_id: nil, founder_id: nil}
  end

  # Returns true if the name of the map sent to it is allowed
  defp is_map_allowed?(_, %{lobby_policy: %{map_list: []}}), do: true
  defp is_map_allowed?(current_map, state) do
    if Enum.empty?(state.lobby_policy.map_list) do
      Logger.error("Error at: #{__ENV__.file}:#{__ENV__.line} - This shouldn't fire")
      true
    else
      map_name = current_map
        |> String.downcase()
        |> String.replace(" ", "_")

      state.lobby_policy.map_list
        |> Enum.filter(fn allowed_map ->
          allowed_name = allowed_map
            |> String.downcase()
            |> String.replace(" ", "_")

          String.contains?(map_name, allowed_name)
        end)
        |> Enum.any?
    end
  end

  defp pick_random_map(%{lobby_policy: %{map_list: []}}), do: :ok
  defp pick_random_map(state) do
    picked_map = Enum.random(state.lobby_policy.map_list)
    send_to_founder(state, "!map #{picked_map}")
  end

  defp generate_lobby_name(state) do
    state.lobby_policy.lobby_name_format
      |> String.replace("{agent}", state.base_name)
      |> String.replace("{id}", "#{state.lobby_policy.id}")
  end

  defp generate_welcome_message(_state) do
    [
      "This is an experimental server-managed lobby. It is in a testing phase so please feel free to try and break it. Chat $settings to me to get the maplist and other information.",
      "Feedback is welcome in the discord thread - https://discord.com/channels/549281623154229250/1085711899817152603"
    ]
  end

  @spec start_link(List.t()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts[:data], [])
  end

  @impl true
  @spec init(Map.t()) :: {:ok, Map.t()}
  def init(data) do
    id = data.lobby_policy.id

    :ok = PubSub.subscribe(Central.PubSub, "lobby_policy_internal:#{id}")
    :ok = PubSub.subscribe(Central.PubSub, "teiserver_client_messages:#{data.userid}")

    Horde.Registry.register(
      Teiserver.LobbyPolicyRegistry,
      "LobbyPolicyBotServer:#{data.userid}",
      id
    )

    {user, _client} = case User.internal_client_login(data.userid) do
      {:ok, user, client} -> {user, client}
      :error -> raise "No user found"
    end

    # Logger.metadata([request_id: "LobbyPolicyBotServer##{id}/#{user.name}"])

    :timer.send_interval(@tick_interval, :tick)

    {:ok, %{
      lobby_policy: data.lobby_policy,
      lobby_id: nil,
      founder_id: nil,
      userid: user.id,
      base_name: data.base_name,
      user: user
    }}
  end
end
