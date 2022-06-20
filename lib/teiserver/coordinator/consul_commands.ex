defmodule Teiserver.Coordinator.ConsulCommands do
  require Logger
  alias Teiserver.Coordinator.{ConsulServer, RikerssMemes}
  alias Teiserver.{Account, Coordinator, User, Client}
  alias Teiserver.Battle.{Lobby, LobbyChat}
  # alias Phoenix.PubSub
  alias Teiserver.Data.Types, as: T
  import Central.Helpers.NumberHelper, only: [int_parse: 1]

  @doc """
    Command has structure:
    %{
      raw: string,
      remaining: string,
      command: nil | string,
      senderid: userid
    }
  """
  @splitter "---------------------------"
  @split_delay 30_000
  @spec handle_command(Map.t(), Map.t()) :: Map.t()
  @default_ban_reason "Banned"

  #################### For everybody
  def handle_command(%{command: "s"} = cmd, state), do: handle_command(Map.put(cmd, :command, "status"), state)
  def handle_command(%{command: "status", senderid: senderid} = _cmd, state) do
    locks = state.locks
      |> Enum.map(fn l -> to_string(l) end)
      |> Enum.join(", ")

    pos_str = case get_queue_position(get_queue(state), senderid) do
      -1 ->
        nil
      pos ->
        if Enum.member?(state.low_priority_join_queue, senderid) do
          "You are position #{pos + 1} but in the low prority queue so other users may be added in front of you"
        else
          "You are position #{pos + 1} in the queue"
        end
    end

    queue_string = get_queue(state)
      |> Enum.map(&User.get_username/1)
      |> Enum.join(", ")

    player_count = ConsulServer.get_player_count(state)

    max_player_count = ConsulServer.get_max_player_count(state)

    boss_string = case state.host_bosses do
      [] -> "Nobody is bossed"
      [boss_id] ->
        "Host boss is: #{User.get_username(boss_id)}"
      boss_ids ->
        boss_names = boss_ids
          |> Enum.map(fn b -> User.get_username(b) end)
          |> Enum.join(", ")

        "Host bosses are: #{boss_names}"
    end

    # Put other settings in here
    other_settings = [
      (if state.welcome_message, do: "Welcome message: #{state.welcome_message}"),
      "Team size set to #{state.host_teamsize}",
      "Team count set to #{state.host_teamcount}",
      boss_string,
      "Currently I think there are #{player_count} players",
      "I think the maximum allowed number of players is #{max_player_count} (Host = #{state.host_teamsize * state.host_teamcount}, Coordinator = #{state.player_limit})",
      "Level required to play is #{state.level_to_play}",
      "Level required to spectate is #{state.level_to_spectate}",
    ]
    |> Enum.filter(fn v -> v != nil end)

    status_msg = [
      @splitter,
      "Status for battle ##{state.lobby_id}",
      "Locks: #{locks}",
      "Gatekeeper: #{state.gatekeeper}",
      pos_str,
      "Join queue: #{queue_string}",
      other_settings,
    ]
    |> List.flatten
    |> Enum.filter(fn s -> s != nil end)

    Coordinator.send_to_user(senderid, status_msg)
    state
  end

  def handle_command(%{command: "roll", remaining: remaining, senderid: senderid} = _cmd, state) do
    username = User.get_username(senderid)

    dice_regex = Regex.run(~r/^(\d+)[dD](\d+)$/, remaining)
    max_format = Regex.run(~r/^(\d+)$/, remaining)
    min_max_format = Regex.run(~r/^(\d+) (\d+)$/, remaining)

    cond do
      dice_regex != nil ->
        [_all, n_dice, s_dice] = dice_regex
        n_dice = int_parse(n_dice) |> max(1) |> min(100)
        s_dice = int_parse(s_dice) |> max(1) |> min(100)

        result = Range.new(1, n_dice)
          |> Enum.map(fn _ -> :rand.uniform(s_dice) end)
          |> Enum.sum

        LobbyChat.say(state.coordinator_id, "#{username} rolled #{n_dice}D#{s_dice} and got a result of: #{result}", state.lobby_id)

      max_format != nil ->
        [_all, smax] = max_format
        nmax = int_parse(smax)

        if nmax > 0 do
          result = :rand.uniform(nmax)
          LobbyChat.say(state.coordinator_id, "#{username} rolled for a number between 1 and #{nmax}, they got: #{result}", state.lobby_id)
        else
          LobbyChat.sayprivateex(state.coordinator_id, senderid, "Format not recognised, please consult the help for this command for more information.", state.lobby_id)
        end

      min_max_format != nil ->
        [_all, smin, smax] = min_max_format
        nmin = int_parse(smin)
        nmax = int_parse(smax)

        if nmax > nmin and nmin > 0 do
          result = nmin + :rand.uniform(nmax - nmin)
          LobbyChat.say(state.coordinator_id, "#{username} rolled for a number between #{nmin} and #{nmax}, they got: #{result}", state.lobby_id)
        else
          LobbyChat.sayprivateex(state.coordinator_id, senderid, "Format not recognised, please consult the help for this command for more information.", state.lobby_id)
        end



      true ->
        LobbyChat.sayprivateex(state.coordinator_id, senderid, "Format not recognised, please consult the help for this command for more information.", state.lobby_id)
    end
    state
  end

  def handle_command(%{command: "afks", senderid: senderid} = cmd, state) do
    min_diff_ms = 20_000
    max_diff_s = 300
    now = System.system_time(:millisecond)
    lobby = Lobby.get_lobby(state.lobby_id)

    if lobby.in_progress do
      Coordinator.send_to_user(senderid, "The game is currently in progress, we cannot check for AFK at this time")
    else
      lines = state.last_seen_map
        |> Enum.filter(fn {userid, seen_at} ->
          Enum.member?(lobby.players, userid) and (now - seen_at) > min_diff_ms
        end)
        |> Enum.filter(fn {userid, _seen_at} ->
          Client.get_client_by_id(userid).player
        end)
        |> Enum.map(fn {userid, seen_at} ->
          seconds_ago = ((now - seen_at)/1000) |> round
          {userid, seconds_ago}
        end)
        |> Enum.sort_by(fn {_userid, seconds_ago  } -> seconds_ago   end, &<=/2)
        |> Enum.map(fn {userid, seconds_ago} ->
          if seconds_ago > max_diff_s do
            "#{User.get_username(userid)} is almost certainly afk"
          else
            "#{User.get_username(userid)} last seen #{seconds_ago}s ago"
          end
        end)

      case lines do
        [] ->
          Coordinator.send_to_user(senderid, "No afk users found")
        _ ->
          Coordinator.send_to_user(senderid, [@splitter, "The following users may be afk"] ++ lines)
      end
    end

    ConsulServer.say_command(cmd, state)
    state
  end

  def handle_command(%{command: "splitlobby", senderid: senderid} = cmd, %{split: nil} = state) do
    ConsulServer.say_command(cmd, state)
    sender_name = User.get_username(senderid)

    Lobby.get_lobby_players!(state.lobby_id)
    |> Enum.each(fn playerid ->
      User.send_direct_message(state.coordinator_id, playerid, [
        @splitter,
        "#{sender_name} is moving to a new lobby, to follow them say $y.",
        "If you want to follow someone else then say $follow <name> and you will follow that user.",
        "The split will take place in #{round(@split_delay/1_000)} seconds",
        "You can change your mind at any time. Say $n to cancel your decision and stay here.",
        @splitter,
      ])
    end)

    User.send_direct_message(state.coordinator_id, senderid, [
      "Splitlobby sequence started. If you stay in this lobby you will be moved to a random empty lobby.",
      "If you choose a lobby yourself then anybody voting yes will follow you to that lobby.",
      @splitter,
    ])

    split_uuid = UUID.uuid4()

    new_split = %{
      split_uuid: split_uuid,
      first_splitter_id: senderid,
      splitters: %{}
    }

    Logger.info("Started split lobby #{Kernel.inspect new_split}")

    :timer.send_after(@split_delay, {:do_split, split_uuid})
    %{state | split: new_split}
  end

  def handle_command(%{command: "splitlobby", senderid: senderid} = _cmd, state) do
    LobbyChat.sayprivateex(state.coordinator_id, senderid, "A split is already underway, you cannot start a new one yet", state.lobby_id)
    state
  end

  # Split commands for when there is no split happening
  def handle_command(%{command: "y"}, %{split: nil} = state), do: state
  def handle_command(%{command: "n"}, %{split: nil} = state), do: state
  def handle_command(%{command: "follow"}, %{split: nil} = state), do: state

  # And for when it is
  def handle_command(%{command: "n", senderid: senderid} = cmd, state) do
    ConsulServer.say_command(cmd, state)
    Logger.info("Split.n from #{senderid}")

    new_splitters = Map.delete(state.split.splitters, senderid)
    new_split = %{state.split | splitters: new_splitters}
    %{state | split: new_split}
  end

  def handle_command(%{command: "y", senderid: senderid} = cmd, state) do
    ConsulServer.say_command(cmd, state)
    Logger.info("Split.y from #{senderid}")

    new_splitters = Map.put(state.split.splitters, senderid, true)
    new_split = %{state.split | splitters: new_splitters}
    %{state | split: new_split}
  end

  def handle_command(%{command: "follow", remaining: target, senderid: senderid} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      player_id ->
        ConsulServer.say_command(cmd, state)
        Logger.info("Split.follow from #{senderid}")

        new_splitters = if player_id == state.split.first_splitter_id do
          Map.put(state.split.splitters, senderid, true)
        else
          Map.put(state.split.splitters, senderid, player_id)
        end

        new_split = %{state.split | splitters: new_splitters}
        %{state | split: new_split}
    end
  end

  def handle_command(%{command: "joinq", senderid: senderid} = _cmd, state) do
    client = Client.get_client_by_id(senderid)
    cond do
      client == nil ->
        state

      User.is_restricted?(senderid, ["Game queue"]) ->
        LobbyChat.sayprivateex(state.coordinator_id, senderid, "You are restricted from joining from joining the queue", state.lobby_id)
        state

      client.player ->
        LobbyChat.sayprivateex(state.coordinator_id, senderid, "You are already a player, you can't join the queue!", state.lobby_id)
        state

      Enum.member?(get_queue(state), senderid) ->
        pos = get_queue_position(get_queue(state), senderid) + 1
        LobbyChat.sayprivateex(state.coordinator_id, senderid, "You were already in the join-queue at position #{pos}. Use $status to check on the queue and $leaveq to leave it.", state.lobby_id)
        state

      true ->
        send(self(), :queue_check)

        new_state = if User.is_restricted?(senderid, ["Low priority"]) do
          %{state | low_priority_join_queue: state.low_priority_join_queue ++ [senderid]}
        else
          %{state | join_queue: state.join_queue ++ [senderid]}
        end

        new_queue = get_queue(new_state)
        pos = get_queue_position(new_queue, senderid) + 1

        if User.is_restricted?(senderid, ["Low priority"]) do
          LobbyChat.sayprivateex(state.coordinator_id, senderid, "You are now in the low priority join-queue at position #{pos}, this means you will be added to the game after normal-priority members. Use $status to check on the queue.", state.lobby_id)
        else
          LobbyChat.sayprivateex(state.coordinator_id, senderid, "You are now in the join-queue at position #{pos}. Use $status to check on the queue.", state.lobby_id)
        end

        new_state
    end
  end

  def handle_command(%{command: "leaveq", senderid: senderid}, state) do
    LobbyChat.sayprivateex(state.coordinator_id, senderid, "You have been removed from the join queue", state.lobby_id)
    %{state |
      join_queue: state.join_queue |> List.delete(senderid),
      low_priority_join_queue: state.low_priority_join_queue |> List.delete(senderid)
    }
  end


  #################### Boss
  def handle_command(%{command: "gatekeeper", remaining: mode, senderid: senderid} = cmd, state) do
    state = case mode do
      "friends" ->
        LobbyChat.say(state.coordinator_id, "Gatekeeper mode set to friends, only friends of a player can join the lobby", state.lobby_id)
        %{state | gatekeeper: :friends}
      "friendsplay" ->
        LobbyChat.say(state.coordinator_id, "Gatekeeper mode set to friendsplay, only friends of a player can play in the lobby (anybody can join)", state.lobby_id)
        %{state | gatekeeper: :friendsplay}
      "default" ->
        LobbyChat.say(state.coordinator_id, "Gatekeeper reset", state.lobby_id)
        %{state | gatekeeper: :default}
      _ ->
        LobbyChat.sayprivateex(state.coordinator_id, senderid, "No gatekeeper of that type (accepted types are: friends, friendsplay)", state.lobby_id)
        state
    end
    ConsulServer.say_command(cmd, state)
  end

  def handle_command(cmd = %{command: "welcome-message", remaining: remaining}, state) do
    new_state = case String.trim(remaining) do
      "" ->
        %{state | welcome_message: nil}
      msg ->
        ConsulServer.say_command(cmd, state)
        Lobby.sayex(state.coordinator_id, "New welcome message set to: #{msg}", state.lobby_id)
        %{state | welcome_message: msg}
    end
    ConsulServer.broadcast_update(new_state)
  end

  def handle_command(%{command: "reset_approval"} = cmd, state) do
    players = Lobby.get_lobby_players!(state.lobby_id)
    new_state = %{state | approved_users: players}
    ConsulServer.say_command(cmd, new_state)
  end


  #################### Host and Moderator
  def handle_command(%{command: "leveltoplay", remaining: remaining, senderid: senderid} = cmd, state) do
    case Integer.parse(remaining |> String.trim) do
      :error ->
        Lobby.sayprivateex(state.coordinator_id, senderid, [
          "No level of that type",
        ], state.lobby_id)
        state
      {level, _} ->
        ConsulServer.say_command(cmd, state)
        %{state | level_to_play: level}
    end
  end

  def handle_command(%{command: "leveltospectate", remaining: remaining, senderid: senderid} = cmd, state) do
    case Integer.parse(remaining |> String.trim) do
      :error ->
        Lobby.sayprivateex(state.coordinator_id, senderid, [
          "No level of that type",
        ], state.lobby_id)
        state
      {level, _} ->
        ConsulServer.say_command(cmd, state)
        %{state | level_to_spectate: level}
    end
  end

  def handle_command(%{command: "lock", remaining: remaining, senderid: senderid} = cmd, state) do
    new_locks = case get_lock(remaining) do
      nil ->
        Lobby.sayprivateex(state.coordinator_id, senderid, [
          "No lock of that type",
        ], state.lobby_id)
        state.locks
      lock ->
        ConsulServer.say_command(cmd, state)
        [lock | state.locks] |> Enum.uniq
    end
    %{state | locks: new_locks}
  end

  def handle_command(%{command: "unlock", remaining: remaining, senderid: senderid} = cmd, state) do
    new_locks = case get_lock(remaining) do
      nil ->
        Lobby.sayprivateex(state.coordinator_id, senderid, [
          "No lock of that type",
        ], state.lobby_id)
        state.locks
      lock ->
        ConsulServer.say_command(cmd, state)
        List.delete(state.locks, lock)
    end
    %{state | locks: new_locks}
  end

  def handle_command(%{command: "specunready"} = cmd, state) do
    battle = Lobby.get_lobby(state.lobby_id)

    battle.players
    |> Enum.each(fn player_id ->
      client = Account.get_client_by_id(player_id)
      if client.ready == false and client.player == true do
        User.ring(player_id, state.coordinator_id)
        Lobby.force_change_client(state.coordinator_id, player_id, %{player: false})
      end
    end)

    ConsulServer.say_command(cmd, state)
  end

  def handle_command(%{command: "makeready", remaining: ""} = cmd, state) do
    battle = Lobby.get_lobby(state.lobby_id)

    battle.players
    |> Enum.each(fn player_id ->
      client = Client.get_client_by_id(player_id)
      if client.ready == false and client.player == true do
        User.ring(player_id, state.coordinator_id)
        Lobby.force_change_client(state.coordinator_id, player_id, %{ready: true})
      end
    end)

    ConsulServer.say_command(cmd, state)
  end

  def handle_command(%{command: "makeready", remaining: target} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      player_id ->
        User.ring(player_id, state.coordinator_id)
        Lobby.force_change_client(state.coordinator_id, player_id, %{ready: true})
        ConsulServer.say_command(cmd, state)
    end
  end

  #################### Moderator only
  # ----------------- General commands
  def handle_command(%{command: "playerlimit", remaining: value_str, senderid: senderid} = cmd, state) do
    case Integer.parse(value_str) do
      {new_limit, _} ->
        ConsulServer.say_command(cmd, state)
        %{state | player_limit: abs(new_limit)}
      _ ->
        LobbyChat.sayprivateex(state.coordinator_id, senderid, "Unable to convert #{value_str} into an integer", state.lobby_id)
        state
    end
  end

  def handle_command(%{command: "success"} = cmd, %{split: nil} = state) do
    ConsulServer.say_command(cmd, state)
    lobby = Lobby.get_lobby(state.lobby_id)
    lobby.players
      |> Enum.map(fn userid -> Client.get_client_by_id(userid) end)
      |> Enum.filter(fn client -> client.player == true end)
      |> Enum.each(fn client ->
        Lobby.say(client.userid, "!y", state.lobby_id)
      end)
    state
  end

  def handle_command(%{command: "cancelsplit"}, %{split: nil} = state) do
    state
  end

  def handle_command(%{command: "cancelsplit"} = cmd, state) do
    :timer.send_after(50, :cancel_split)
    ConsulServer.say_command(cmd, state)
  end

  def handle_command(%{command: "dosplit"}, %{split: nil} = state) do
    state
  end

  def handle_command(%{command: "dosplit"} = cmd, %{split: split} = state) do
    :timer.send_after(50, {:do_split, split.split_uuid})
    ConsulServer.say_command(cmd, state)
  end

  def handle_command(%{command: "specafk", senderid: senderid} = cmd, state) do
    lobby = Lobby.get_lobby(state.lobby_id)
    if lobby.in_progress do
      Coordinator.send_to_user(senderid, "The game is currently in progress, we cannot spec-afk members")
    else
      afk_check_list = ConsulServer.list_players(state)
        |> Enum.map(fn %{userid: userid} -> userid end)

      afk_check_list
        |> Enum.each(fn userid ->
          User.ring(userid, state.coordinator_id)
          User.send_direct_message(state.coordinator_id, userid, "The lobby you are in is conducting an AFK check, please respond with 'hello' here to show you are not afk or just type something into the lobby chat.")
        end)

      ConsulServer.say_command(cmd, %{state |
        afk_check_list: afk_check_list,
        afk_check_at: System.system_time(:millisecond)
      })
    end
  end

  def handle_command(%{command: "rename", remaining: new_name, senderid: senderid} = cmd, state) do
    lobby = Lobby.get_lobby(state.lobby_id)
    cond do
      senderid != lobby.founder_id ->
        Lobby.rename_lobby(state.lobby_id, new_name, true)

      lobby.consul_rename ->
        :ok

      true ->
        Lobby.rename_lobby(state.lobby_id, new_name, false)
    end
    ConsulServer.say_command(cmd, state)
  end

  def handle_command(%{command: "vip", remaining: target, senderid: senderid} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      target_id ->
        ConsulServer.say_command(cmd, state)
        sender_name = User.get_username(senderid)
        Lobby.sayex(state.coordinator_id, "#{sender_name} placed #{target} at the front of the join queue", state.lobby_id)
        %{state | join_queue: Enum.uniq([target_id] ++ state.join_queue)}
    end
  end

  def handle_command(%{command: "pull", remaining: target} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      target_id ->
        Lobby.force_add_user_to_battle(target_id, state.lobby_id)
        ConsulServer.say_command(cmd, state)
    end
  end

  def handle_command(%{command: "settag", remaining: remaining} = cmd, state) do
    case String.split(remaining, " ") do
      [key, value | _] ->
        battle = Lobby.get_lobby(state.lobby_id)
        new_tags = Map.put(battle.tags, String.downcase(key), value)
        Lobby.set_script_tags(state.lobby_id, new_tags)
        ConsulServer.say_command(cmd, state)
      _ ->
        ConsulServer.say_command(%{cmd | error: "no regex match"}, state)
    end
  end

  # ----------------- Moderation commands
  def handle_command(%{command: "balance"} = cmd, state) do
    lobby = Lobby.get_lobby(state.lobby_id)
    if lobby.consul_balance do
      send(self(), :balance)
      ConsulServer.say_command(cmd, state)
    end
    state
  end

  def handle_command(%{command: "balancemode", remaining: type, senderid: senderid} = cmd, state) do
    type = type
      |> String.downcase()
      |> String.trim()

    case type do
      "consul" ->
        lobby = Lobby.get_lobby(state.lobby_id)
        Lobby.update_lobby(%{lobby | consul_balance: true}, nil, :balance)
        ConsulServer.say_command(cmd, state)
        Lobby.sayex(state.coordinator_id, "Balance mode changed to Consul mode", state.lobby_id)

        new_locks = ["team" | state.locks] |> Enum.uniq
        %{state | locks: new_locks}

      "spads" ->
        lobby = Lobby.get_lobby(state.lobby_id)
        Lobby.update_lobby(%{lobby | consul_balance: false}, nil, :balance)
        ConsulServer.say_command(cmd, state)
        Lobby.sayex(state.coordinator_id, "Balance mode changed to SPADS mode", state.lobby_id)

        new_locks = List.delete(state.locks, "team")
        %{state | locks: new_locks}
      _ ->
        LobbyChat.sayprivateex(state.coordinator_id, senderid, "No balancemode of that name, accepts consul and spads", state.lobby_id)
        state
    end
  end

  def handle_command(%{command: "speclock", remaining: target} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        state
      target_id ->
        ban = new_ban(%{level: :spectator, by: cmd.senderid}, state)
        new_bans = Map.put(state.bans, target_id, ban)

        Lobby.force_change_client(state.coordinator_id, target_id, %{player: false})

        ConsulServer.say_command(cmd, state)

        %{state | bans: new_bans}
    end
  end

  def handle_command(%{command: "forceplay", remaining: target} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        state
      target_id ->
        Lobby.force_change_client(state.coordinator_id, target_id, %{player: true, ready: true})
        ConsulServer.say_command(cmd, state)
    end
  end

  def handle_command(%{command: "timeout", remaining: target} = cmd, state) do
    [target | reason_list] = String.split(target, " ")
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      target_id ->
        reason = if reason_list == [], do: "You have been given a timeout on the naughty step", else: Enum.join(reason_list, " ")
        timeout = new_timeout(%{level: :banned, by: cmd.senderid, reason: reason}, state)
        new_timeouts = Map.put(state.timeouts, target_id, timeout)

        Lobby.kick_user_from_battle(target_id, state.lobby_id)

        ConsulServer.say_command(cmd, state)

        %{state | timeouts: new_timeouts}
          |> ConsulServer.broadcast_update("timeout")
    end
  end

  def handle_command(%{command: "lobbykick", remaining: target} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      target_id ->
        Lobby.kick_user_from_battle(target_id, state.lobby_id)

        ConsulServer.say_command(cmd, state)
    end
  end

  def handle_command(%{command: "lobbyban", remaining: target} = cmd, state) do
    [target | reason_list] = String.split(target, " ")
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      target_id ->
        reason = if reason_list == [], do: @default_ban_reason, else: Enum.join(reason_list, " ")
        ban = new_ban(%{level: :banned, by: cmd.senderid, reason: reason}, state)
        new_bans = Map.put(state.bans, target_id, ban)

        Lobby.kick_user_from_battle(target_id, state.lobby_id)

        ConsulServer.say_command(cmd, state)

        %{state | bans: new_bans}
        |> ConsulServer.broadcast_update("ban")
    end
  end

  def handle_command(%{command: "lobbybanmult", remaining: targets} = cmd, state) do
    {targets, reason} = case String.split(targets, "!!") do
      [t] -> {t, @default_ban_reason}
      [t, r | _] -> {t, String.trim(r)}
    end
    ConsulServer.say_command(cmd, state)

    String.split(targets, " ")
    |> Enum.reduce(state, fn (target, acc) ->
      case ConsulServer.get_user(target, acc) do
        nil ->
          acc
        target_id ->
          ban = new_ban(%{level: :banned, by: cmd.senderid, reason: reason}, acc)
          new_bans = Map.put(acc.bans, target_id, ban)
          Lobby.kick_user_from_battle(target_id, acc.lobby_id)

          %{acc | bans: new_bans}
          |> ConsulServer.broadcast_update("ban")
      end
    end)
  end

  def handle_command(%{command: "unban", remaining: target} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      target_id ->
        new_bans = Map.drop(state.bans, [target_id])
        ConsulServer.say_command(cmd, state)

        %{state | bans: new_bans}
        |> ConsulServer.broadcast_update("unban")
    end
  end

  # This is here to make tests easier to run, it's not expected you'll use this and it's not in the docs
  def handle_command(%{command: "forcespec", remaining: target} = cmd, state) do
    case ConsulServer.get_user(target, state) do
      nil ->
        ConsulServer.say_command(%{cmd | error: "no user found"}, state)
      target_id ->
        ban = new_ban(%{level: :spectator, by: cmd.senderid, reason: "forcespec"}, state)
        new_bans = Map.put(state.bans, target_id, ban)

        Lobby.force_change_client(state.coordinator_id, target_id, %{player: false})

        ConsulServer.say_command(cmd, state)

        %{state | bans: new_bans}
        |> ConsulServer.broadcast_update("ban")
    end
  end

  def handle_command(%{command: "meme", remaining: meme, senderid: senderid}, state) do
    meme = String.downcase(meme)

    msg = RikerssMemes.handle_meme(meme, senderid, state)

    if not Enum.empty?(msg) do
      Lobby.get_lobby_players!(state.lobby_id)
      |> Enum.each(fn playerid ->
        User.send_direct_message(state.coordinator_id, playerid, msg)
      end)
    end

    state
  end

  def handle_command(%{command: "reset"} = _cmd, state) do
    ConsulServer.empty_state(state.lobby_id)
    |> ConsulServer.broadcast_update("reset")
  end

  #################### Internal commands
  # Would need to be sent by internal since battlestatus isn't part of the command queue
  def handle_command(%{command: "change-battlestatus", remaining: target_id, status: new_status}, state) do
    Lobby.force_change_client(state.coordinator_id, target_id, new_status)
    state
  end

  def handle_command(%{senderid: senderid} = cmd, state) do
    if Map.has_key?(cmd, :raw) do
      # LobbyChat.do_say(cmd.senderid, cmd.raw, state.lobby_id)
      LobbyChat.sayprivateex(state.coordinator_id, senderid, "No command of that name", state.lobby_id)
    else
      Logger.error("No handler in consul_server for command #{Kernel.inspect cmd}")
    end
    state
  end

  defp new_ban(data, state) do
    Map.merge(%{
      by: state.coordinator_id,
      reason: @default_ban_reason,
      # :player | :spectator | :banned
      level: :banned
    }, data)
  end

  defp new_timeout(data, state) do
    Map.merge(%{
      by: state.coordinator_id,
      reason: "You have been given a timeout on the naughty step",
      # :player | :spectator | :banned
      level: :banned
    }, data)
  end

  @spec get_lock(String.t()) :: atom | nil
  defp get_lock(name) do
    case name |> String.downcase |> String.trim do
      "team" -> :team
      "allyid" -> :allyid
      "player" -> :player
      "spectator" -> :spectator
      "boss" -> :boss
      _ -> nil
    end
  end

  defp get_queue_position(queue, userid) do
    case Enum.member?(queue, userid) do
      true ->
        Enum.with_index(queue)
        |> Map.new
        |> Map.get(userid)
      false ->
        -1
    end
  end

  @spec get_queue(map()) :: [T.userid()]
  defdelegate get_queue(state), to: ConsulServer
end
