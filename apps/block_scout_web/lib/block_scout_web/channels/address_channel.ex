defmodule BlockScoutWeb.AddressChannel do
  @moduledoc """
  Establishes pub/sub channel for address page live updates.
  """
  use BlockScoutWeb, :channel
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  import Explorer.Chain.SmartContract, only: [burn_address_hash_string: 0]

  alias BlockScoutWeb.API.V2.AddressView, as: AddressViewAPI
  alias BlockScoutWeb.API.V2.SmartContractView, as: SmartContractViewAPI
  alias BlockScoutWeb.API.V2.TransactionView, as: TransactionViewAPI

  alias BlockScoutWeb.{
    AddressCoinBalanceView,
    AddressView,
    InternalTransactionView,
    TransactionView
  }

  alias Explorer.{Chain, Market, Repo}
  alias Explorer.Chain.{Hash, Transaction, Wei}
  alias Explorer.Chain.Hash.Address, as: AddressHash
  alias Phoenix.View

  intercept([
    "balance_update",
    "coin_balance",
    "count",
    "internal_transaction",
    "transaction",
    "verification_result",
    "token_transfer",
    "pending_transaction",
    "address_current_token_balances"
  ])

  {:ok, burn_address_hash} = Chain.string_to_address_hash(burn_address_hash_string())
  @burn_address_hash burn_address_hash
  @current_token_balances_limit 50

  case @chain_type do
    :celo ->
      @chain_type_transaction_associations [
        :gas_token
      ]

    _ ->
      @chain_type_transaction_associations []
  end

  @transaction_associations [
                              from_address: [:scam_badge, :names, :smart_contract, proxy_implementations_association()],
                              to_address: [
                                :scam_badge,
                                :names,
                                :smart_contract,
                                proxy_implementations_association()
                              ],
                              created_contract_address: [
                                :scam_badge,
                                :names,
                                :smart_contract,
                                proxy_implementations_association()
                              ]
                            ] ++
                              @chain_type_transaction_associations

  def join("addresses:" <> address_hash, _params, socket) do
    {:ok, %{}, assign(socket, :address_hash, address_hash)}
  end

  def handle_in("get_balance", _, socket) do
    with {:ok, casted_address_hash} <- AddressHash.cast(socket.assigns.address_hash),
         {:ok, address = %{fetched_coin_balance: balance}} when not is_nil(balance) <-
           Chain.hash_to_address(casted_address_hash),
         exchange_rate <- Market.get_coin_exchange_rate(),
         {:ok, rendered} <- render_balance_card(address, exchange_rate, socket) do
      reply =
        {:ok,
         %{
           balance_card: rendered,
           balance: address.fetched_coin_balance.value,
           fetched_coin_balance_block_number: address.fetched_coin_balance_block_number
         }}

      {:reply, reply, socket}
    else
      _ ->
        {:noreply, socket}
    end
  end

  def handle_out(
        "balance_update",
        %{address: address, exchange_rate: exchange_rate},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket
      ) do
    push(socket, "balance", %{
      balance: address.fetched_coin_balance.value,
      block_number: address.fetched_coin_balance_block_number,
      exchange_rate: exchange_rate.usd_value
    })

    {:noreply, socket}
  end

  def handle_out(
        "balance_update",
        %{address: address, exchange_rate: exchange_rate},
        socket
      ) do
    case render_balance_card(address, exchange_rate, socket) do
      {:ok, rendered} ->
        push(socket, "balance", %{
          balance_card: rendered,
          balance: address.fetched_coin_balance.value,
          fetched_coin_balance_block_number: address.fetched_coin_balance_block_number
        })

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_out(
        "verification_result",
        %{result: result},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket
      ) do
    case result do
      {:ok, _contract} ->
        push(socket, "verification_result", %{status: "success"})
        {:noreply, socket}

      {:error, changeset} ->
        push(socket, "verification_result", %{
          status: "error",
          errors: SmartContractViewAPI.render("changeset_errors.json", %{changeset: changeset})
        })

        {:noreply, socket}
    end
  end

  def handle_out("verification_result", result, socket) do
    case result[:result] do
      {:ok, _contract} ->
        push(socket, "verification", %{verification_result: :ok})
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, socket}

      {:error, result} ->
        push(socket, "verification", %{verification_result: result})
        {:noreply, socket}
    end
  end

  def handle_out("count", %{count: count}, %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket) do
    push(socket, "count", %{count: to_string(count)})

    {:noreply, socket}
  end

  def handle_out("count", %{count: count}, socket) do
    Gettext.put_locale(BlockScoutWeb.Gettext, socket.assigns.locale)

    push(socket, "count", %{count: BlockScoutWeb.Cldr.Number.to_string!(count, format: "#,###")})

    {:noreply, socket}
  end

  # TODO: fix or remove, "internal_transaction.json" clause does not exist
  def handle_out(
        "internal_transaction",
        %{address: _address, internal_transaction: internal_transaction},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket
      ) do
    internal_transaction_json =
      TransactionViewAPI.render("internal_transaction.json", %{
        internal_transaction: internal_transaction,
        conn: nil
      })

    push(socket, "internal_transaction", %{internal_transaction: internal_transaction_json})

    {:noreply, socket}
  end

  def handle_out("internal_transaction", %{address: address, internal_transaction: internal_transaction}, socket) do
    Gettext.put_locale(BlockScoutWeb.Gettext, socket.assigns.locale)

    rendered_internal_transaction =
      View.render_to_string(
        InternalTransactionView,
        "_tile.html",
        current_address: address,
        internal_transaction: internal_transaction
      )

    push(socket, "internal_transaction", %{
      to_address_hash: to_string(internal_transaction.to_address_hash),
      from_address_hash: to_string(internal_transaction.from_address_hash),
      internal_transaction_html: rendered_internal_transaction
    })

    {:noreply, socket}
  end

  def handle_out("transaction", data, socket), do: handle_transaction(data, socket, "transaction")

  def handle_out("token_transfer", data, socket), do: handle_token_transfer(data, socket, "token_transfer")

  def handle_out(
        "coin_balance",
        %{block_number: block_number},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket
      ) do
    coin_balance = Chain.get_coin_balance(socket.assigns.address_hash, block_number)

    if coin_balance.value && coin_balance.delta do
      rendered_coin_balance = AddressViewAPI.render("coin_balance.json", %{coin_balance: coin_balance})

      push(socket, "coin_balance", %{coin_balance: rendered_coin_balance})

      push_current_coin_balance(socket, block_number, coin_balance)
    end

    {:noreply, socket}
  end

  def handle_out("coin_balance", %{block_number: block_number}, socket) do
    coin_balance = Chain.get_coin_balance(socket.assigns.address_hash, block_number)

    Gettext.put_locale(BlockScoutWeb.Gettext, socket.assigns.locale)

    if coin_balance.value && coin_balance.delta do
      rendered_coin_balance =
        View.render_to_string(
          AddressCoinBalanceView,
          "_coin_balances.html",
          conn: socket,
          coin_balance: coin_balance
        )

      push(socket, "coin_balance", %{
        coin_balance_html: rendered_coin_balance
      })

      push_current_coin_balance(socket, block_number, coin_balance)
    end

    {:noreply, socket}
  end

  def handle_out("pending_transaction", data, %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket),
    do: handle_transaction(data, socket, "pending_transaction")

  def handle_out("pending_transaction", data, socket), do: handle_transaction(data, socket, "transaction")

  def handle_out(
        "address_current_token_balances",
        %{address_current_token_balances: address_current_token_balances},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket
      ) do
    push_current_token_balances(socket, address_current_token_balances, "erc_20", "ERC-20")
    push_current_token_balances(socket, address_current_token_balances, "erc_721", "ERC-721")
    push_current_token_balances(socket, address_current_token_balances, "erc_1155", "ERC-1155")
    push_current_token_balances(socket, address_current_token_balances, "erc_404", "ERC-404")

    {:noreply, socket}
  end

  def handle_out("address_current_token_balances", _, socket) do
    {:noreply, socket}
  end

  defp push_current_token_balances(socket, address_current_token_balances, event_postfix, token_type) do
    filtered_ctbs =
      address_current_token_balances
      |> Enum.filter(fn ctb -> ctb.token_type == token_type end)
      |> Enum.sort_by(
        fn ctb ->
          value =
            if ctb.token.decimals,
              do: Decimal.div(ctb.value, Decimal.new(Integer.pow(10, Decimal.to_integer(ctb.token.decimals)))),
              else: ctb.value

          {(ctb.token.fiat_value && Decimal.mult(value, ctb.token.fiat_value)) || Decimal.new(0), value}
        end,
        &sorter/2
      )

    push(socket, "updated_token_balances_" <> event_postfix, %{
      token_balances:
        AddressViewAPI.render("token_balances.json", %{
          token_balances: Enum.take(filtered_ctbs, @current_token_balances_limit)
        }),
      overflow: Enum.count(filtered_ctbs) > @current_token_balances_limit
    })
  end

  defp sorter({fiat_value_1, value_1}, {fiat_value_2, value_2}) do
    case {Decimal.compare(fiat_value_1, fiat_value_2), Decimal.compare(value_1, value_2)} do
      {:gt, _} -> true
      {:eq, :gt} -> true
      {:eq, :eq} -> true
      _ -> false
    end
  end

  def push_current_coin_balance(
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket,
        block_number,
        coin_balance
      ) do
    push(socket, "current_coin_balance", %{
      coin_balance: (coin_balance && coin_balance.value) || %Wei{value: Decimal.new(0)},
      exchange_rate: Market.get_coin_exchange_rate().usd_value,
      block_number: block_number
    })
  end

  def push_current_coin_balance(socket, block_number, coin_balance) do
    {:ok, hash} = Chain.string_to_address_hash(socket.assigns.address_hash)

    rendered_current_coin_balance =
      View.render_to_string(
        AddressView,
        "_current_coin_balance.html",
        conn: socket,
        address: Chain.hash_to_address(hash),
        coin_balance: (coin_balance && coin_balance.value) || %Wei{value: Decimal.new(0)},
        exchange_rate: Market.get_coin_exchange_rate()
      )

    rendered_link =
      View.render_to_string(
        AddressView,
        "_block_link.html",
        conn: socket,
        block_number: block_number
      )

    push(socket, "current_coin_balance", %{
      current_coin_balance_html: rendered_current_coin_balance,
      current_coin_balance_block_number_html: rendered_link,
      current_coin_balance_block_number: coin_balance.block_number
    })
  end

  def handle_transaction(
        %{transactions: transactions},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket,
        event
      )
      when is_list(transactions) do
    transaction_json =
      TransactionViewAPI.render("transactions.json", %{
        transactions:
          transactions
          |> Repo.preload(@transaction_associations),
        conn: nil
      })

    push(socket, event, %{transactions: transaction_json})

    {:noreply, socket}
  end

  def handle_transaction(
        %{address: address, transaction: transaction},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocket} = socket,
        event
      ) do
    Gettext.put_locale(BlockScoutWeb.Gettext, socket.assigns.locale)

    rendered =
      View.render_to_string(
        TransactionView,
        "_tile.html",
        conn: socket,
        current_address: address,
        transaction: transaction,
        burn_address_hash: @burn_address_hash
      )

    push(socket, event, %{
      to_address_hash: to_string(transaction.to_address_hash),
      from_address_hash: to_string(transaction.from_address_hash),
      transaction_hash: Hash.to_string(transaction.hash),
      transaction_html: rendered
    })

    {:noreply, socket}
  end

  def handle_transaction(_, socket, _event) do
    {:noreply, socket}
  end

  def handle_token_transfer(
        %{token_transfers: token_transfers},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocketV2} = socket,
        event
      )
      when is_list(token_transfers) do
    token_transfer_json =
      TransactionViewAPI.render("token_transfers.json", %{
        token_transfers:
          token_transfers
          |> Repo.preload([
            [
              from_address: [:scam_badge, :names, :smart_contract, proxy_implementations_association()],
              to_address: [:scam_badge, :names, :smart_contract, proxy_implementations_association()]
            ]
          ]),
        conn: nil
      })

    push(socket, event, %{token_transfers: token_transfer_json})

    {:noreply, socket}
  end

  def handle_token_transfer(
        %{address: address, token_transfer: token_transfer},
        %Phoenix.Socket{handler: BlockScoutWeb.UserSocket} = socket,
        event
      ) do
    Gettext.put_locale(BlockScoutWeb.Gettext, socket.assigns.locale)

    transaction =
      Transaction
      |> Repo.get_by(hash: token_transfer.transaction_hash)
      |> Repo.preload([
        :from_address,
        :to_address,
        :block,
        :created_contract_address,
        token_transfers: [:from_address, :to_address, :token]
      ])

    rendered =
      View.render_to_string(
        TransactionView,
        "_tile.html",
        current_address: address,
        transaction: transaction,
        burn_address_hash: @burn_address_hash,
        conn: socket
      )

    push(socket, event, %{
      to_address_hash: to_string(token_transfer.to_address_hash),
      from_address_hash: to_string(token_transfer.from_address_hash),
      token_transfer_hash: Hash.to_string(token_transfer.transaction_hash),
      token_transfer_html: rendered
    })

    {:noreply, socket}
  end

  def handle_token_transfer(_, socket, _event) do
    {:noreply, socket}
  end

  defp render_balance_card(address, exchange_rate, socket) do
    Gettext.put_locale(BlockScoutWeb.Gettext, socket.assigns.locale)

    try do
      rendered =
        View.render_to_string(
          AddressView,
          "_balance_dropdown.html",
          conn: socket,
          address: address,
          coin_balance_status: :current,
          exchange_rate: exchange_rate
        )

      {:ok, rendered}
    rescue
      _ ->
        :error
    end
  end
end
