defmodule Plausible.Billing do
  use Plausible.Repo
  require Plausible.Billing.Subscription.Status
  alias Plausible.Billing.{Subscription, Plans, Quota}

  def upgrade_route_for(user) do
    action = if FunWithFlags.enabled?(:business_tier, for: user), do: :choose_plan, else: :upgrade
    PlausibleWeb.Router.Helpers.billing_path(PlausibleWeb.Endpoint, action)
  end

  @spec active_subscription_for(integer()) :: Subscription.t() | nil
  def active_subscription_for(user_id) do
    user_id |> active_subscription_query() |> Repo.one()
  end

  @spec has_active_subscription?(integer()) :: boolean()
  def has_active_subscription?(user_id) do
    user_id |> active_subscription_query() |> Repo.exists?()
  end

  def subscription_created(params) do
    Repo.transaction(fn ->
      handle_subscription_created(params)
    end)
  end

  def subscription_updated(params) do
    Repo.transaction(fn ->
      handle_subscription_updated(params)
    end)
  end

  def subscription_cancelled(params) do
    Repo.transaction(fn ->
      handle_subscription_cancelled(params)
    end)
  end

  def subscription_payment_succeeded(params) do
    Repo.transaction(fn ->
      handle_subscription_payment_succeeded(params)
    end)
  end

  def change_plan(user, new_plan_id) do
    subscription = active_subscription_for(user.id)
    plan = Plans.find(new_plan_id)

    with :ok <- Quota.ensure_can_subscribe_to_plan(user, plan),
         do: do_change_plan(subscription, new_plan_id)
  end

  defp do_change_plan(subscription, new_plan_id) do
    res =
      paddle_api().update_subscription(subscription.paddle_subscription_id, %{
        plan_id: new_plan_id
      })

    case res do
      {:ok, response} ->
        amount = :erlang.float_to_binary(response["next_payment"]["amount"] / 1, decimals: 2)

        Subscription.changeset(subscription, %{
          paddle_plan_id: Integer.to_string(response["plan_id"]),
          next_bill_amount: amount,
          next_bill_date: response["next_payment"]["date"]
        })
        |> Repo.update()

      e ->
        e
    end
  end

  def change_plan_preview(subscription, new_plan_id) do
    case paddle_api().update_subscription_preview(
           subscription.paddle_subscription_id,
           new_plan_id
         ) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec check_needs_to_upgrade(Plausible.Auth.User.t()) ::
          {:needs_to_upgrade, :no_trial | :no_active_subscription | :grace_period_ended}
          | :no_upgrade_needed
  def check_needs_to_upgrade(%Plausible.Auth.User{trial_expiry_date: nil}) do
    {:needs_to_upgrade, :no_trial}
  end

  def check_needs_to_upgrade(user) do
    user = Plausible.Users.with_subscription(user)
    trial_is_over = Timex.before?(user.trial_expiry_date, Timex.today())
    subscription_active = subscription_is_active?(user.subscription)

    cond do
      trial_is_over && !subscription_active -> {:needs_to_upgrade, :no_active_subscription}
      Plausible.Auth.GracePeriod.expired?(user) -> {:needs_to_upgrade, :grace_period_ended}
      true -> :no_upgrade_needed
    end
  end

  defp subscription_is_active?(%Subscription{status: Subscription.Status.active()}), do: true
  defp subscription_is_active?(%Subscription{status: Subscription.Status.past_due()}), do: true

  defp subscription_is_active?(
         %Subscription{status: Subscription.Status.deleted()} = subscription
       ) do
    subscription.next_bill_date && !Timex.before?(subscription.next_bill_date, Timex.today())
  end

  defp subscription_is_active?(%Subscription{}), do: false
  defp subscription_is_active?(nil), do: false

  def on_trial?(%Plausible.Auth.User{trial_expiry_date: nil}), do: false

  def on_trial?(user) do
    user = Plausible.Users.with_subscription(user)
    !subscription_is_active?(user.subscription) && trial_days_left(user) >= 0
  end

  def trial_days_left(user) do
    Timex.diff(user.trial_expiry_date, Timex.today(), :days)
  end

  @spec last_two_billing_months_usage(Plausible.Auth.User.t(), Date.t()) ::
          {non_neg_integer(), non_neg_integer()}
  def last_two_billing_months_usage(user, today \\ Timex.today()) do
    {first, second} = last_two_billing_cycles(user, today)

    site_ids = Plausible.Sites.owned_site_ids(user)

    usage_for_sites = fn site_ids, date_range ->
      {pageviews, custom_events} =
        Plausible.Stats.Clickhouse.usage_breakdown(site_ids, date_range)

      pageviews + custom_events
    end

    {
      usage_for_sites.(site_ids, first),
      usage_for_sites.(site_ids, second)
    }
  end

  def last_two_billing_cycles(user, today \\ Timex.today()) do
    last_bill_date = user.subscription.last_bill_date

    normalized_last_bill_date =
      Timex.shift(last_bill_date,
        months: Timex.diff(today, last_bill_date, :months)
      )

    {
      Date.range(
        Timex.shift(normalized_last_bill_date, months: -2),
        Timex.shift(normalized_last_bill_date, days: -1, months: -1)
      ),
      Date.range(
        Timex.shift(normalized_last_bill_date, months: -1),
        Timex.shift(normalized_last_bill_date, days: -1)
      )
    }
  end

  def usage_breakdown(user) do
    site_ids = Plausible.Sites.owned_site_ids(user)
    Plausible.Stats.Clickhouse.usage_breakdown(site_ids)
  end

  defp handle_subscription_created(params) do
    params =
      if present?(params["passthrough"]) do
        params
      else
        user = Repo.get_by(Plausible.Auth.User, email: params["email"])
        Map.put(params, "passthrough", user && user.id)
      end

    %Subscription{}
    |> Subscription.changeset(format_subscription(params))
    |> Repo.insert!()
    |> after_subscription_update()
  end

  defp handle_subscription_updated(params) do
    subscription = Repo.get_by(Subscription, paddle_subscription_id: params["subscription_id"])

    if subscription do
      subscription
      |> Subscription.changeset(format_subscription(params))
      |> Repo.update!()
      |> after_subscription_update()
    end
  end

  defp handle_subscription_cancelled(params) do
    subscription =
      Subscription
      |> Repo.get_by(paddle_subscription_id: params["subscription_id"])
      |> Repo.preload(:user)

    if subscription do
      changeset =
        Subscription.changeset(subscription, %{
          status: params["status"]
        })

      updated = Repo.update!(changeset)

      subscription
      |> Map.fetch!(:user)
      |> PlausibleWeb.Email.cancellation_email()
      |> Plausible.Mailer.send()

      updated
    end
  end

  defp handle_subscription_payment_succeeded(params) do
    subscription = Repo.get_by(Subscription, paddle_subscription_id: params["subscription_id"])

    if subscription do
      {:ok, api_subscription} = paddle_api().get_subscription(subscription.paddle_subscription_id)

      amount =
        :erlang.float_to_binary(api_subscription["next_payment"]["amount"] / 1, decimals: 2)

      subscription
      |> Subscription.changeset(%{
        next_bill_amount: amount,
        next_bill_date: api_subscription["next_payment"]["date"],
        last_bill_date: api_subscription["last_payment"]["date"]
      })
      |> Repo.update!()
    end
  end

  defp format_subscription(params) do
    %{
      paddle_subscription_id: params["subscription_id"],
      paddle_plan_id: params["subscription_plan_id"],
      cancel_url: params["cancel_url"],
      update_url: params["update_url"],
      user_id: params["passthrough"],
      status: params["status"],
      next_bill_date: params["next_bill_date"],
      next_bill_amount: params["unit_price"] || params["new_unit_price"],
      currency_code: params["currency"]
    }
  end

  defp present?(""), do: false
  defp present?(nil), do: false
  defp present?(_), do: true

  defp maybe_remove_grace_period(%Plausible.Auth.User{} = user) do
    alias Plausible.Auth.GracePeriod

    case user.grace_period do
      %GracePeriod{allowance_required: allowance_required} ->
        new_monthly_pageview_limit =
          Plausible.Billing.Quota.monthly_pageview_limit(user.subscription)

        if new_monthly_pageview_limit > allowance_required do
          user
          |> Plausible.Auth.GracePeriod.remove_changeset()
          |> Repo.update!()
        else
          user
        end

      _ ->
        user
    end
  end

  def paddle_api(), do: Application.fetch_env!(:plausible, :paddle_api)

  defp active_subscription_query(user_id) do
    from(s in Subscription,
      where: s.user_id == ^user_id and s.status == ^Subscription.Status.active(),
      order_by: [desc: s.inserted_at],
      limit: 1
    )
  end

  defp after_subscription_update(subscription) do
    user =
      Plausible.Auth.User
      |> Repo.get!(subscription.user_id)
      |> Map.put(:subscription, subscription)

    user
    |> maybe_remove_grace_period()
    |> tap(&Plausible.Billing.SiteLocker.update_sites_for/1)
    |> maybe_adjust_api_key_limits()
  end

  defp maybe_adjust_api_key_limits(user) do
    plan =
      Repo.get_by(Plausible.Billing.EnterprisePlan,
        user_id: user.id,
        paddle_plan_id: user.subscription.paddle_plan_id
      )

    if plan do
      user_id = user.id
      api_keys = from(key in Plausible.Auth.ApiKey, where: key.user_id == ^user_id)
      Repo.update_all(api_keys, set: [hourly_request_limit: plan.hourly_api_request_limit])
    end

    user
  end
end
