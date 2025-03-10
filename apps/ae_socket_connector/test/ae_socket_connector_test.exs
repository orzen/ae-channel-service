defmodule SocketConnectorTest do
  use ExUnit.Case
  require ClientRunner
  require Logger

  @ae_url ClientRunner.ae_url()
  @network_id ClientRunner.network_id()

  def gen_names(id) do
    clean_id = Atom.to_string(id)
    {String.to_atom("alice " <> clean_id), String.to_atom("bob " <> clean_id)}
  end

  def custom_config(overide_basic_param, override_custom) do
    fn initator_pub, responder_pub ->
      %{basic_configuration: basic_configuration} =
        Map.merge(
          ClientRunner.default_configuration(initator_pub, responder_pub),
          overide_basic_param
        )

      %{
        basic_configuration: basic_configuration,
        custom_param_fun: fn role, host_url ->
          Map.merge(ClientRunner.custom_connection_setting(role, host_url), override_custom)
        end
      }
    end
  end

  def accounts_initiator() do
    {TestAccounts.initiatorPubkeyEncoded(), TestAccounts.initiatorPrivkey()}
  end

  def accounts_responder() do
    {TestAccounts.responderPubkeyEncoded(), TestAccounts.responderPrivkey()}
  end

  @tag :hello_world
  test "hello fsm", context do
    {alice, bob} = gen_names(context.test)

    scenario = fn {initiator, _intiator_account}, {responder, _responder_account}, runner_pid ->
      [
        # opening channel
        {:responder, %{message: {:channels_info, 0, :transient, "channel_open"}}},
        {:initiator, %{message: {:channels_info, 0, :transient, "channel_accept"}}},
        {:initiator, %{message: {:sign_approve, 1, "channels.sign.initiator_sign"}}},
        {:responder, %{message: {:channels_info, 0, :transient, "funding_created"}}},
        {:responder, %{message: {:sign_approve, 1, "channels.sign.responder_sign"}}},
        {:responder, %{message: {:on_chain, 0, :transient, "funding_created"}}},
        {:initiator, %{message: {:channels_info, 0, :transient, "funding_signed"}}},
        {:initiator, %{message: {:on_chain, 0, :transient, "funding_signed"}}},
        # {:responder, %{message: {:on_chain, 0, :transient, "channel_changed"}}},
        {:responder, %{fuzzy: 1, message: {:channels_info, 0, :transient, "own_funding_locked"}}},
        # {:initiator, %{message: {:on_chain, 0, :transient, "channel_changed"}}},
        {:initiator, %{fuzzy: 1, message: {:channels_info, 0, :transient, "own_funding_locked"}}},
        {:initiator, %{fuzzy: 1, message: {:channels_info, 0, :transient, "funding_locked"}}},
        {:responder, %{fuzzy: 1, message: {:channels_info, 0, :transient, "funding_locked"}}},
        {:initiator, %{message: {:channels_info, 0, :transient, "open"}}},
        {:initiator,
         %{
           message: {:channels_update, 1, :self, "channels.update"},
           next: {:async, fn pid -> SocketConnector.leave(pid) end, :empty},
           fuzzy: 3
         }},
        {:responder, %{message: {:channels_info, 0, :transient, "open"}}},
        {:responder, %{message: {:channels_update, 1, :other, "channels.update"}}},
        # end of opening sequence
        # leaving
        {:responder,
         %{
           message: {:channels_update, 1, :transient, "channels.leave"},
           fuzzy: 1,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
         }},
        {:initiator, %{message: {:channels_update, 1, :transient, "channels.leave"}, fuzzy: 1}},
        {:initiator,
         %{
           message: {:channels_info, 0, :transient, "died"},
           fuzzy: 0,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
         }}
      ]
    end

    ClientRunner.start_peers(
      @ae_url,
      @network_id,
      {alice, accounts_initiator()},
      {bob, accounts_responder()},
      scenario,
      custom_config(%{}, %{minimum_depth: 0, port: 1400})
    )
  end

  @tag :hello_world_mini
  test "hello fsm mini", context do
    {alice, bob} = gen_names(context.test)

    scenario = fn {initiator, _intiator_account}, {responder, _responder_account}, runner_pid ->
      [
        {:initiator,
         %{
           message: {:channels_update, 1, :self, "channels.update"},
           next: {:async, fn pid -> SocketConnector.leave(pid) end, :empty},
           fuzzy: 10
         }},
        {:responder,
         %{
           message: {:channels_update, 1, :transient, "channels.leave"},
           fuzzy: 20,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
         }},
        {:initiator,
         %{
           message: {:channels_info, 0, :transient, "died"},
           fuzzy: 20,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
         }}
      ]
    end

    ClientRunner.start_peers(
      @ae_url,
      @network_id,
      {alice, accounts_initiator()},
      {bob, accounts_responder()},
      scenario,
      custom_config(%{}, %{minimum_depth: 0, port: 1401})
    )
  end

  @tag :cancel
  test "cancel transfer", context do
    {alice, bob} = gen_names(context.test)

    scenario = fn {initiator, _intiator_account}, {responder, _responder_account}, runner_pid ->
      [
        {:initiator,
         %{
           message: {:sign_approve, 1, "channels.sign.initiator_sign"},
           fuzzy: 10
         }},
        # {:responder,
        #  %{
        #    message: {:sign_approve, 1, "channels.sign.initiator_sign"},
        #    fuzzy: 10
        #  }},
        {:initiator,
         %{
           message: {:channels_update, 1, :self, "channels.update"},
           next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 5) end, :empty},
           fuzzy: 10
         }},
        {:initiator,
         %{
           message: {:sign_approve, 2, "channels.sign.update"},
           fuzzy: 10,
           sign: :cancel
         }},
        {:responder,
         %{
           message: {:sign_approve, 2, "channels.sign.update_ack"},
           fuzzy: 10
         }},
        {:initiator,
         %{
           message: {:channels_update, 2, :self, "channels.update"},
           next: {:async, fn pid -> SocketConnector.leave(pid) end, :empty},
           fuzzy: 10
         }},
        {:responder,
         %{
           message: {:channels_update, 2, :transient, "channels.leave"},
           fuzzy: 20,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
         }},
        {:initiator,
         %{
           message: {:channels_info, 0, :transient, "died"},
           fuzzy: 20,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
         }}
      ]
    end

    ClientRunner.start_peers(
      @ae_url,
      @network_id,
      {alice, accounts_initiator()},
      {bob, accounts_responder()},
      scenario,
      custom_config(%{}, %{minimum_depth: 0, port: 1402})
    )
  end

  # this test works locally again and again, but temporary removed for circle ci
  # @tag :ignore
  # @tag :close_on_chain
  # test "close on chain", context do
  #   {alice, bob} = gen_names(context.test)

  #   scenario = fn {initiator, intiator_account}, {responder, _responder_account}, runner_pid ->
  #     [
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 1, :self, "channels.update"},
  #          next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 5) end, :empty},
  #          fuzzy: 8
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 2, :self, "channels.update"},
  #          next: {:sync, fn pid, from -> SocketConnector.get_poi(pid, from) end, :empty},
  #          fuzzy: 5
  #        }},
  #       {:initiator,
  #        %{
  #          next:
  #            {:local,
  #             fn client_runner, pid_session_holder ->
  #               nonce = OnChain.nonce(intiator_account)
  #               height = OnChain.current_height()
  #               Logger.debug("nonce is #{inspect(nonce)} height is: #{inspect(height)}")

  #               transaction =
  #                 GenServer.call(
  #                   pid_session_holder,
  #                   {:solo_close_transaction, 2, nonce + 1, height}
  #                 )

  #               OnChain.post_solo_close(transaction)
  #               ClientRunnerHelper.resume_runner(client_runner)
  #             end, :empty}
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:on_chain, 0, :transient, "solo_closing"},
  #          fuzzy: 10,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
  #        }},
  #       {:responder,
  #        %{
  #          message: {:on_chain, 0, :transient, "solo_closing"},
  #          fuzzy: 20,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
  #        }}
  #     ]
  #   end

  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     scenario,
  #     custom_config(%{}, %{minimum_depth: 0, port: 1403})
  #   )
  # end

  # this test works locally again and again, but temporary removed for circle ci
  # @tag :close_on_chain_mal
  # test "close on chain maliscous", context do
  #   {alice, bob} = gen_names(context.test)

  #   scenario = fn {initiator, intiator_account}, {responder, _responder_account}, runner_pid ->
  #     [
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 1, :self, "channels.update"},
  #          next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 5) end, :empty},
  #          fuzzy: 8
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 2, :self, "channels.update"},
  #          next: {:sync, fn pid, from -> SocketConnector.get_poi(pid, from) end, :empty},
  #          fuzzy: 5
  #        }},
  #       {:initiator,
  #        %{
  #          next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 7) end, :empty},
  #          fuzzy: 8
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 3, :self, "channels.update"},
  #          next: {:sync, fn pid, from -> SocketConnector.get_poi(pid, from) end, :empty},
  #          fuzzy: 5
  #        }},
  #       {:initiator,
  #        %{
  #          next:
  #            {:local,
  #             fn client_runner, pid_session_holder ->
  #               nonce = OnChain.nonce(intiator_account)
  #               height = OnChain.current_height()

  #               transaction =
  #                 GenServer.call(
  #                   pid_session_holder,
  #                   {:solo_close_transaction, 2, nonce + 1, height}
  #                 )

  #               OnChain.post_solo_close(transaction)
  #               ClientRunnerHelper.resume_runner(client_runner)
  #             end, :empty}
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:on_chain, 0, :transient, "can_slash"},
  #          fuzzy: 10,
  #          next: {:sync, fn pid, from -> SocketConnector.slash(pid, from) end, :empty}
  #          #  next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
  #        }},
  #       {:responder,
  #        %{
  #          message: {:on_chain, 0, :transient, "can_slash"},
  #          fuzzy: 20,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:on_chain, 0, :transient, "solo_closing"},
  #          fuzzy: 5,
  #          next: {:async, fn pid -> SocketConnector.settle(pid) end, :empty}
  #          #  next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:channels_info, 0, :transient, "closed_confirmed"},
  #          fuzzy: 10,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
  #        }},
  #       {:responder,
  #        %{
  #          message: {:channels_info, 0, :transient, "closed_confirmed"},
  #          fuzzy: 20,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
  #        }}
  #     ]
  #   end

  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     scenario,
  #     custom_config(%{}, %{minimum_depth: 0, port: 1404})
  #   )
  # end

  @tag :reconnect
  test "withdraw after re-connect", context do
    {alice, bob} = gen_names(context.test)

    scenario = fn {initiator, _intiator_account}, {responder, _responder_account}, runner_pid ->
      [
        {:initiator,
         %{
           message: {:channels_update, 1, :self, "channels.update"},
           next:
             {:local,
              fn client_runner, pid_session_holder ->
                SessionHolder.close_connection(pid_session_holder)
                ClientRunnerHelper.resume_runner(client_runner)
              end, :empty},
           fuzzy: 10
         }},
        {:initiator, %{next: ClientRunnerHelper.pause_job(1000)}},
        {:initiator,
         %{
           next:
             {:local,
              fn client_runner, pid_session_holder ->
                SessionHolder.reconnect(pid_session_holder, 1510)
                ClientRunnerHelper.resume_runner(client_runner)
              end, :empty},
           fuzzy: 0
         }},
        {:initiator,
         %{
           next:
             {:async,
              fn pid ->
                SocketConnector.withdraw(pid, 1_000_000)
              end, :empty},
           fuzzy: 0
         }},
        {:responder,
         %{
           message: {:channels_update, 2, :other, "channels.update"},
           fuzzy: 20,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
         }},
        {:initiator,
         %{
           message: {:channels_update, 2, :self, "channels.update"},
           fuzzy: 20,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
         }}
      ]
    end

    ClientRunner.start_peers(
      @ae_url,
      @network_id,
      {alice, accounts_initiator()},
      {bob, accounts_responder()},
      scenario,
      custom_config(%{}, %{minimum_depth: 0, port: 1405})
    )
  end

  # test "withdraw after reestablish", context do
  #   {alice, bob} = gen_names(context.test)

  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     &TestScenarios.withdraw_after_reestablish_v2/3
  #   )
  # end

  # @tag :backchannel
  # test "backchannel jobs", context do
  #   {alice, bob} = gen_names(context.test)

  #   scenario = fn {initiator, intiator_account}, {responder, responder_account}, runner_pid ->
  #     [
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 1, :self, "channels.update"},
  #          next:
  #            {:local,
  #             fn client_runner, pid_session_holder ->
  #               SessionHolder.close_connection(pid_session_holder)
  #               ClientRunnerHelper.resume_runner(client_runner)
  #             end, :empty},
  #          fuzzy: 20
  #        }},
  #       {:responder,
  #        %{
  #          next:
  #            ClientRunnerHelper.assert_funds_job(
  #              {intiator_account, 6_999_999_999_999},
  #              {responder_account, 4_000_000_000_001}
  #            )
  #        }},
  #       {:responder,
  #        %{
  #          message: {:channels_update, 1, :other, "channels.update"},
  #          next: ClientRunnerHelper.pause_job(3000),
  #          fuzzy: 10
  #        }},
  #       # this updates should fail, since other end is gone.
  #       {:responder,
  #        %{
  #          next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 2) end, :empty}
  #        }},
  #       {:responder,
  #        %{
  #          message: {:channels_update, 2, :self, "channels.conflict"},
  #          fuzzy: 2,
  #          next:
  #            {:async,
  #             fn pid ->
  #               SocketConnector.initiate_transfer(pid, 4, fn to_sign ->
  #                 SessionHolder.backchannel_sign_request(initiator, to_sign)
  #               end)
  #             end, :empty}
  #        }},
  #       {:responder,
  #        %{
  #          message: {:channels_update, 2, :self, "channels.update"},
  #          fuzzy: 3,
  #          next:
  #            ClientRunnerHelper.assert_funds_job(
  #              {intiator_account, 7_000_000_000_003},
  #              {responder_account, 3_999_999_999_997}
  #            )
  #        }},
  #       {:responder,
  #        %{
  #          next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 5) end, :empty}
  #        }},
  #       {:initiator, %{next: ClientRunnerHelper.pause_job(10000)}},
  #       {:initiator,
  #        %{
  #          next:
  #            {:local,
  #             fn client_runner, pid_session_holder ->
  #               SessionHolder.reconnect(pid_session_holder, 1233)
  #               ClientRunnerHelper.resume_runner(client_runner)
  #             end, :empty}
  #        }},
  #       {:initiator,
  #        %{
  #          next:
  #            ClientRunnerHelper.assert_funds_job(
  #              {intiator_account, 7_000_000_000_003},
  #              {responder_account, 3_999_999_999_997}
  #            )
  #        }},
  #       {:initiator,
  #        %{
  #          next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 5) end, :empty}
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 3, :self, "channels.update"},
  #          fuzzy: 3,
  #          next:
  #            ClientRunnerHelper.assert_funds_job(
  #              {intiator_account, 6_999_999_999_998},
  #              {responder_account, 4_000_000_000_002}
  #            )
  #        }},
  #       {:responder,
  #        %{
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
  #        }},
  #       {:initiator,
  #        %{
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
  #        }}
  #     ]
  #   end
  #
  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     scenario
  #   )
  # end

  def close_solo_job() do
    # special cased since this doesn't end up in an update.
    close_solo = fn pid -> SocketConnector.close_solo(pid) end

    {:local,
     fn client_runner, pid_session_holder ->
       SessionHolder.run_action(pid_session_holder, close_solo)
       ClientRunnerHelper.resume_runner(client_runner)
     end, :empty}
  end

  @tag :close_solo
  # @tag timeout: 60000 * 10
  test "close solo", context do
    {alice, bob} = gen_names(context.test)

    scenario = fn {initiator, _intiator_account}, {responder, _responder_account}, runner_pid ->
      [
        {:initiator,
         %{
           message: {:channels_update, 1, :self, "channels.update"},
           next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 5) end, :empty},
           fuzzy: 8
         }},
        {:initiator,
         %{
           message: {:channels_update, 2, :self, "channels.update"},
           next: close_solo_job(),
           fuzzy: 8
         }},
        {:initiator,
         %{
           message: {:channels_info, 0, :transient, "closing"},
           fuzzy: 15,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
         }},
        {:responder,
         %{
           message: {:channels_info, 0, :transient, "closing"},
           fuzzy: 15,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
         }}
      ]
    end

    ClientRunner.start_peers(
      @ae_url,
      @network_id,
      {alice, accounts_initiator()},
      {bob, accounts_responder()},
      scenario,
      custom_config(%{}, %{minimum_depth: 0, port: 1406})
      # custom_config(%{}, %{minimum_depth: 1})
    )
  end

  def close_mutual_job() do
    # special cased since this doesn't end up in an update.
    shutdown = fn pid -> SocketConnector.shutdown(pid) end

    {:local,
     fn client_runner, pid_session_holder ->
       SessionHolder.run_action(pid_session_holder, shutdown)
       ClientRunnerHelper.resume_runner(client_runner)
     end, :empty}
  end

  # @tag :close_mut
  # test "close mutual", context do
  #   {alice, bob} = gen_names(context.test)

  #   scenario = fn {initiator, _intiator_account}, {responder, _responder_account}, runner_pid ->
  #     [
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 1, :self, "channels.update"},
  #          next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 5) end, :empty},
  #          fuzzy: 8
  #        }},
  #       #  get poi is done under the hood, but this call tests additional code
  #       {:initiator,
  #        %{
  #          message: {:channels_update, 2, :self, "channels.update"},
  #          next: {:sync, fn pid, from -> SocketConnector.get_poi(pid, from) end, :empty},
  #          fuzzy: 8
  #        }},
  #       {:initiator,
  #        %{
  #          #  message: {:channels_update, 2, :self, "channels.update"},
  #          next: close_mutual_job(),
  #          fuzzy: 8
  #        }},
  #       {:initiator,
  #        %{
  #          message: {:channels_info, 0, :transient, "closed_confirmed"},
  #          fuzzy: 10,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
  #        }},
  #       {:responder,
  #        %{
  #          message: {:channels_info, 0, :transient, "closed_confirmed"},
  #          fuzzy: 20,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
  #        }}
  #     ]
  #   end

  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     scenario
  #   )
  # end

  test "reconnect jobs", context do
    {alice, bob} = gen_names(context.test)

    scenario = fn {initiator, intiator_account}, {responder, responder_account}, runner_pid ->
      [
        {:initiator,
         %{
           message: {:channels_update, 1, :self, "channels.update"},
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_999_999_999},
               {responder_account, 4_000_000_000_001}
             ),
           fuzzy: 10
         }},
        {:initiator,
         %{
           next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 2) end, :empty}
         }},
        {:initiator,
         %{
           message: {:channels_update, 3, :other, "channels.update"},
           fuzzy: 10,
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
         }},
        {:responder,
         %{
           message: {:channels_update, 2, :other, "channels.update"},
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_999_999_997},
               {responder_account, 4_000_000_000_003}
             ),
           fuzzy: 15
         }},
        {:responder,
         %{
           #  message: {:channels_update, 1, :self, "channels.update"},
           next:
             {:local,
              fn client_runner, pid_session_holder ->
                SessionHolder.close_connection(pid_session_holder)
                ClientRunnerHelper.resume_runner(client_runner)
              end, :empty}
         }},
        {:responder, %{next: ClientRunnerHelper.pause_job(1000)}},
        {:responder,
         %{
           next:
             {:local,
              fn client_runner, pid_session_holder ->
                SessionHolder.reconnect(pid_session_holder)
                ClientRunnerHelper.resume_runner(client_runner)
              end, :empty}
         }},
        {:responder,
         %{
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_999_999_997},
               {responder_account, 4_000_000_000_003}
             )
         }},
        {:responder,
         %{
           next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 2) end, :empty}
         }},
        {:responder,
         %{
           message: {:channels_update, 3, :self, "channels.update"},
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_999_999_999},
               {responder_account, 4_000_000_000_001}
             ),
           fuzzy: 10
         }},
        {:responder,
         %{
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
         }}
      ]
    end

    ClientRunner.start_peers(
      @ae_url,
      @network_id,
      {alice, accounts_initiator()},
      {bob, accounts_responder()},
      scenario,
      custom_config(%{}, %{minimum_depth: 0, port: 1407})
    )
  end

  # relocate contact files to get this working.
  @tag :contract
  test "contract jobs", context do
    {alice, bob} = gen_names(context.test)

    scenario = fn {initiator, intiator_account}, {responder, responder_account}, runner_pid ->
      initiator_contract = {TestAccounts.initiatorPubkeyEncoded(), "../../contracts/TicTacToe.aes"}

      # correct path if started in shell...
      # initiator_contract = {TestAccounts.initiatorPubkeyEncoded(), "contracts/TicTacToe.aes"}
      [
        {:initiator,
         %{
           message: {:channels_update, 1, :self, "channels.update"},
           next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 2) end, :empty},
           fuzzy: 10
         }},
        {:initiator,
         %{
           message: {:channels_update, 2, :self, "channels.update"},
           fuzzy: 3,
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_999_999_997},
               {responder_account, 4_000_000_000_003}
             )
         }},
        {:initiator,
         %{
           next: {:async, fn pid -> SocketConnector.new_contract(pid, initiator_contract) end, :empty}
         }},
        {:initiator,
         %{
           fuzzy: 10,
           message: {:channels_update, 3, :self, "channels.update"},
           next:
             {:async,
              fn pid ->
                SocketConnector.call_contract(
                  pid,
                  initiator_contract,
                  'make_move',
                  ['11', '1']
                )
              end, :empty}
         }},
        {:initiator,
         %{
           fuzzy: 10,
           message: {:channels_update, 4, :self, "channels.update"},
           next:
             {:sync,
              fn pid, from ->
                SocketConnector.get_contract_reponse(
                  pid,
                  initiator_contract,
                  'make_move',
                  from
                )
              end,
              fn a ->
                assert a == {:ok, {:string, [], "Game continues. The other player's turn."}}
              end}
         }},
        {:initiator,
         %{
           next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 3) end, :empty}
         }},
        {:initiator,
         %{
           fuzzy: 10,
           message: {:channels_update, 5, :self, "channels.update"},
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_999_999_984},
               {responder_account, 4_000_000_000_006}
             )
         }},
        {:initiator,
         %{
           next:
             {:async,
              fn pid ->
                SocketConnector.withdraw(pid, 1_000_000)
              end, :empty}
         }},
        {:initiator,
         %{
           fuzzy: 10,
           #  TODO bug somewhere, why do we go for transient here?
           message: {:channels_update, 6, :self, "channels.update"},
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_998_999_984},
               {responder_account, 4_000_000_000_006}
             )
         }},
        {:initiator,
         %{
           next: {:async, fn pid -> SocketConnector.initiate_transfer(pid, 9) end, :empty}
         }},
        {:initiator,
         %{
           message: {:channels_update, 7, :self, "channels.update"},
           fuzzy: 10,
           next:
             {:async,
              fn pid ->
                SocketConnector.deposit(pid, 500_000)
              end, :empty}
         }},
        {:initiator,
         %{
           message: {:channels_update, 8, :self, "channels.update"},
           fuzzy: 10,
           next:
             ClientRunnerHelper.assert_funds_job(
               {intiator_account, 6_999_999_499_975},
               {responder_account, 4_000_000_000_015}
             )
         }},
        {:responder,
         %{
           fuzzy: 50,
           message: {:channels_update, 8, :other, "channels.update"},
           next:
             {:async,
              fn pid ->
                SocketConnector.call_contract(
                  pid,
                  initiator_contract,
                  'make_move',
                  ['11', '2']
                )
              end, :empty}
         }},
        {:responder,
         %{
           fuzzy: 10,
           message: {:channels_update, 9, :self, "channels.update"},
           next:
             {:sync,
              fn pid, from ->
                SocketConnector.get_contract_reponse(
                  pid,
                  initiator_contract,
                  'make_move',
                  from
                )
              end, fn a -> assert a == {:ok, {:string, [], "Place is already taken!"}} end}
         }},
        {:responder,
         %{
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
         }},
        {:initiator,
         %{
           next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
         }}
      ]
    end

    ClientRunner.start_peers(
      @ae_url,
      @network_id,
      {alice, accounts_initiator()},
      {bob, accounts_responder()},
      scenario,
      custom_config(%{}, %{minimum_depth: 0, port: 1408})
    )
  end

  # test "reestablish jobs", context do
  #   {alice, bob} = gen_names(context.test)

  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     &TestScenarios.reestablish_jobs_v2/3
  #   )
  # end

  # test "query after reconnect", context do
  #   {alice, bob} = gen_names(context.test)

  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     &TestScenarios.query_after_reconnect_v2/3
  #   )
  # end

  # @tag :ignore
  # @tag :open_channel_passive
  # # this scenario does not work on circle ci. needs to be investigated
  # test "teardown on channel creation", context do
  #   {alice, bob} = gen_names(context.test)

  #   scenario = fn {initiator, intiator_account}, {responder, responder_account}, runner_pid ->
  #     [
  #       {:initiator,
  #        %{
  #          # worked before
  #          # message: {:channels_info, 0, :transient, "funding_signed"},
  #          # should work now
  #          message: {:channels_info, 0, :transient, "own_funding_locked"},
  #          fuzzy: 10,
  #          next:
  #            {:local,
  #             fn client_runner, pid_session_holder ->
  #               SessionHolder.close_connection(pid_session_holder)
  #               ClientRunnerHelper.resume_runner(client_runner)
  #             end, :empty}
  #        }},
  #       {:initiator, %{next: ClientRunnerHelper.pause_job(10000)}},
  #       {:initiator,
  #        %{
  #          next:
  #            {:local,
  #             fn client_runner, pid_session_holder ->
  #               SessionHolder.reestablish(pid_session_holder, 1501)
  #               ClientRunnerHelper.resume_runner(client_runner)
  #             end, :empty}
  #        }},
  #       # currently no message is received on reconnect.
  #       # to eager fething causes timeout due to missing response.
  #       {:initiator, %{next: ClientRunnerHelper.pause_job(1000)}},
  #       {:initiator,
  #        %{
  #          fuzzy: 3,
  #          next:
  #            ClientRunnerHelper.assert_funds_job(
  #              {intiator_account, 6_999_999_999_999},
  #              {responder_account, 4_000_000_000_001}
  #            )
  #        }},
  #       {:initiator,
  #        %{
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, initiator)
  #        }},
  #       {:responder,
  #        %{
  #          message: {:channels_update, 1, :other, "channels.update"},
  #          fuzzy: 14,
  #          next: ClientRunnerHelper.sequence_finish_job(runner_pid, responder)
  #        }}
  #     ]
  #   end

  #   ClientRunner.start_peers(
  #     @ae_url,
  #     @network_id,
  #     {alice, accounts_initiator()},
  #     {bob, accounts_responder()},
  #     scenario,
  #     custom_config(%{}, %{minimum_depth: 50, port: 1409})
  #   )
  # end

  # scenario = fn {initiator, intiator_account}, {responder, _responder_account}, runner_pid ->
  #   []
  # end
end
