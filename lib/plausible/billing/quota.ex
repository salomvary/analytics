defmodule Plausible.Billing.Quota do
  @moduledoc """
  This module provides functions to work with plans usage and limits.
  """

  import Ecto.Query
  alias Plausible.Billing
  alias Plausible.Billing.{Plan, Plans, Subscription, EnterprisePlan, Feature}
  alias Plausible.Billing.Feature.{Goals, RevenueGoals, Funnels, Props, StatsAPI}

  def usage(user, opts \\ []) do
    basic_usage = %{
      monthly_pageviews: monthly_pageview_usage(user),
      team_members: team_member_usage(user),
      sites: site_usage(user)
    }

    if Keyword.get(opts, :with_features) == true do
      basic_usage
      |> Map.put(:features, features_usage(user))
    else
      basic_usage
    end
  end

  @limit_sites_since ~D[2021-05-05]
  @spec site_limit(Plausible.Auth.User.t()) :: non_neg_integer() | :unlimited
  @doc """
  Returns the limit of sites a user can have.

  For enterprise customers, returns :unlimited. The site limit is checked in a
  background job so as to avoid service disruption.
  """
  def site_limit(user) do
    cond do
      Application.get_env(:plausible, :is_selfhost) -> :unlimited
      Timex.before?(user.inserted_at, @limit_sites_since) -> :unlimited
      true -> get_site_limit_from_plan(user)
    end
  end

  @site_limit_for_trials 10
  @site_limit_for_legacy_trials 50
  @site_limit_for_free_10k 50
  defp get_site_limit_from_plan(user) do
    user = Plausible.Users.with_subscription(user)

    case Plans.get_subscription_plan(user.subscription) do
      %EnterprisePlan{} ->
        :unlimited

      %Plan{site_limit: site_limit} ->
        site_limit

      :free_10k ->
        @site_limit_for_free_10k

      nil ->
        if Timex.before?(user.inserted_at, Plans.business_tier_launch()) do
          @site_limit_for_legacy_trials
        else
          @site_limit_for_trials
        end
    end
  end

  @spec site_usage(Plausible.Auth.User.t()) :: non_neg_integer()
  @doc """
  Returns the number of sites the given user owns.
  """
  def site_usage(user) do
    Plausible.Sites.owned_sites_count(user)
  end

  @monthly_pageview_limit_for_free_10k 10_000
  @monthly_pageview_limit_for_trials :unlimited

  @spec monthly_pageview_limit(Subscription.t()) ::
          non_neg_integer() | :unlimited
  @doc """
  Returns the limit of pageviews for a subscription.
  """
  def monthly_pageview_limit(subscription) do
    case Plans.get_subscription_plan(subscription) do
      %EnterprisePlan{monthly_pageview_limit: limit} ->
        limit

      %Plan{monthly_pageview_limit: limit} ->
        limit

      :free_10k ->
        @monthly_pageview_limit_for_free_10k

      _any ->
        if subscription do
          Sentry.capture_message("Unknown monthly pageview limit for plan",
            extra: %{paddle_plan_id: subscription.paddle_plan_id}
          )
        end

        @monthly_pageview_limit_for_trials
    end
  end

  @spec monthly_pageview_usage(Plausible.Auth.User.t()) :: non_neg_integer()
  @doc """
  Returns the amount of pageviews and custom events
  sent by the sites the user owns in last 30 days.
  """
  def monthly_pageview_usage(user) do
    user
    |> Billing.usage_breakdown()
    |> Tuple.sum()
  end

  @team_member_limit_for_trials 3
  @team_member_limit_for_legacy_trials :unlimited
  @spec team_member_limit(Plausible.Auth.User.t()) :: non_neg_integer()
  @doc """
  Returns the limit of team members a user can have in their sites.
  """
  def team_member_limit(user) do
    user = Plausible.Users.with_subscription(user)

    case Plans.get_subscription_plan(user.subscription) do
      %EnterprisePlan{} ->
        :unlimited

      %Plan{team_member_limit: limit} ->
        limit

      :free_10k ->
        :unlimited

      nil ->
        if Timex.before?(user.inserted_at, Plans.business_tier_launch()) do
          @team_member_limit_for_legacy_trials
        else
          @team_member_limit_for_trials
        end
    end
  end

  @spec team_member_usage(Plausible.Auth.User.t()) :: integer()
  @doc """
  Returns the total count of team members and pending invitations associated
  with the user's sites.
  """
  def team_member_usage(user) do
    Plausible.Repo.aggregate(team_member_usage_query(user), :count)
  end

  @doc false
  def team_member_usage_query(user, site \\ nil) do
    owned_sites_query = owned_sites_query(user)

    owned_sites_query =
      if site do
        where(owned_sites_query, [os], os.site_id == ^site.id)
      else
        owned_sites_query
      end

    team_members_query =
      from os in subquery(owned_sites_query),
        inner_join: sm in Plausible.Site.Membership,
        on: sm.site_id == os.site_id,
        inner_join: u in assoc(sm, :user),
        where: sm.role != :owner,
        select: u.email

    from i in Plausible.Auth.Invitation,
      inner_join: os in subquery(owned_sites_query),
      on: i.site_id == os.site_id,
      where: i.role != :owner,
      select: i.email,
      union: ^team_members_query
  end

  @spec features_usage(Plausible.Auth.User.t()) :: [atom()]
  @doc """
  Returns a list of features the given user is using. At the
  current stage, the only features that we need to know the
  usage for are `Props`, `Funnels`, and `RevenueGoals`
  """
  def features_usage(user) do
    props_usage_query =
      from s in Plausible.Site,
        inner_join: os in subquery(owned_sites_query(user)),
        on: s.id == os.site_id,
        where: fragment("cardinality(?) > 0", s.allowed_event_props)

    funnels_usage_query =
      from f in Plausible.Funnel,
        inner_join: os in subquery(owned_sites_query(user)),
        on: f.site_id == os.site_id

    revenue_goals_usage =
      from g in Plausible.Goal,
        inner_join: os in subquery(owned_sites_query(user)),
        on: g.site_id == os.site_id,
        where: not is_nil(g.currency)

    stats_api_usage = from a in Plausible.Auth.ApiKey, where: a.user_id == ^user.id

    queries = [
      {Props, props_usage_query},
      {Funnels, funnels_usage_query},
      {RevenueGoals, revenue_goals_usage},
      {StatsAPI, stats_api_usage}
    ]

    Enum.reduce(queries, [], fn {feature, query}, acc ->
      if Plausible.Repo.exists?(query), do: acc ++ [feature], else: acc
    end)
  end

  def ensure_can_subscribe_to_plan(user, %Plan{} = plan) do
    case exceeded_limits(usage(user), plan) do
      [] ->
        :ok

      [:monthly_pageview_limit] ->
        # This is a quick fix. Need to figure out how to handle this case. Only
        # checking the last 30 days usage is not accurate enough. Needs to be
        # in sync with the actual locking system.
        :ok

      exceeded_limits ->
        {:error, %{exceeded_limits: exceeded_limits}}
    end
  end

  def ensure_can_subscribe_to_plan(_user, nil), do: :ok

  def exceeded_limits(usage, %Plan{} = plan) do
    for {usage_field, limit_field} <- [
          {:monthly_pageviews, :monthly_pageview_limit},
          {:team_members, :team_member_limit},
          {:sites, :site_limit}
        ],
        !within_limit?(Map.get(usage, usage_field), Map.get(plan, limit_field)) do
      limit_field
    end
  end

  @doc """
  Returns a list of features the user can use. Trial users have the
  ability to use all features during their trial.
  """
  def allowed_features_for(user) do
    user = Plausible.Users.with_subscription(user)

    case Plans.get_subscription_plan(user.subscription) do
      %EnterprisePlan{} -> Feature.list()
      %Plan{features: features} -> features
      :free_10k -> [Goals, Props, StatsAPI]
      nil -> Feature.list()
    end
  end

  defp owned_sites_query(user) do
    from sm in Plausible.Site.Membership,
      where: sm.role == :owner and sm.user_id == ^user.id,
      select: %{site_id: sm.site_id}
  end

  @spec below_limit?(non_neg_integer(), non_neg_integer() | :unlimited) :: boolean()
  @doc """
  Returns whether the usage is below the limit or not.
  Returns false if usage is equal to the limit.
  """
  def below_limit?(usage, limit) do
    if limit == :unlimited, do: true, else: usage < limit
  end

  @spec within_limit?(non_neg_integer(), non_neg_integer() | :unlimited) :: boolean()
  @doc """
  Returns whether the usage is within the limit or not.
  Returns true if usage is equal to the limit.
  """
  def within_limit?(usage, limit) do
    if limit == :unlimited, do: true, else: usage <= limit
  end
end
