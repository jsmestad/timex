defmodule Timex.Timezone do
  @moduledoc """
  Contains all the logic around conversion, manipulation,
  and comparison of time zones.
  """
  alias Timex.Date,           as: Date
  alias Timex.DateTime,       as: DateTime
  alias Timex.TimezoneInfo,   as: TimezoneInfo
  alias Timex.Timezone.Local, as: Local

  @abbreviations Tzdata.canonical_zone_list
                 |> Enum.flat_map(fn name -> {:ok, periods} = Tzdata.periods(name); periods end)
                 |> Enum.map(fn %{:zone_abbr => abbr} -> abbr end)
                 |> Enum.uniq
                 |> Enum.filter(fn abbr -> abbr != "" end)

  @doc """
  Determines if a given zone name exists
  """
  def exists?(zone), do: Tzdata.zone_exists?(zone) || Enum.member?(@abbreviations, zone)

  @doc """
  Get's the current local timezone configuration.
  """
  def local(),                     do: local(Date.now)
  def local({{y,m,d}, {h,min,s}}), do: %DateTime{year: y, month: m, day: d, hour: h, minute: min, second: s, timezone: %TimezoneInfo{}} |> local
  def local(%DateTime{} = for),    do: get(Local.lookup(for), for)

  # UTC is so common, we'll give it an extra shortcut, as well as handle common shortcuts
  def get(tz, for \\ Date.now)

  def get(tz, for) when tz in ["Z", "UT", "GMT"], do: get(:utc, for)
  def get(:utc, _),   do: %TimezoneInfo{}
  def get(0, for),    do: get("UTC", for)
  # These are shorthand for specific time zones
  def get("A", for),  do: get(+1, for)
  def get("M", for),  do: get(+12, for)
  def get("N", for),  do: get(-1, for)
  def get("Y", for),  do: get(-12, for)
  # Allow querying by offset
  def get(offset, for) when is_number(offset) do
    if offset > 0 do
      get("Etc/GMT-#{offset}", for)
    else
      get("Etc/GMT+#{offset * -1}", for)
    end
  end
  def get(<<?+, offset :: binary>>, for) do 
    {num, _} = Integer.parse(offset)
    cond do
      num > 100 -> get(trunc(num/100), for)
      true      -> get(num, for)
    end
  end
  def get(<<?-, offset :: binary>>, for) do
    {num, _} = Integer.parse(offset)
    cond do
      num > 100 -> get(trunc(num/100) * -1, for)
      true      -> get(num, for)
    end
  end

  @doc """
  Gets the TimezoneInfo for an Erlang datetime tuple
  """
  def get(timezone, {{_,_,_}, {_,_,_}} = datetime) do
     case Tzdata.zone_exists?(timezone) do
      false ->
        case @abbreviations |> Enum.member?(timezone) do
          true ->
            # Lookup the real timezone for this abbreviation and date
            seconds_from_zeroyear = :calendar.datetime_to_gregorian_seconds(datetime)
            case lookup_timezone_by_abbreviation(timezone, seconds_from_zeroyear) do
              {:error, _}           -> {:error, "No timezone found for: #{timezone}"}
              {:ok, {name, period}} -> tzdata_to_timezone(period, name)
            end
          false ->
            {:error, "No timezone found for: #{timezone}"}
        end
      true  ->
        seconds_from_zeroyear = :calendar.datetime_to_gregorian_seconds(datetime)
        [period | _] = Tzdata.periods_for_time(timezone, seconds_from_zeroyear, :wall)
        period |> tzdata_to_timezone(timezone)
    end
  end

  @doc """
  Get the TimezoneInfo object corresponding to the given name.
  """
  # Fallback lookup by Standard/Daylight Savings time names/abbreviations
  def get(timezone, for) do
    case Tzdata.zone_exists?(timezone) do
      false ->
        case @abbreviations |> Enum.member?(timezone) do
          true ->
            # Lookup the real timezone for this abbreviation and date
            seconds_from_zeroyear = for |> Date.to_secs(:zero)
            case lookup_timezone_by_abbreviation(timezone, seconds_from_zeroyear) do
              {:error, _}           -> {:error, "No timezone found for: #{timezone}"}
              {:ok, {name, period}} -> tzdata_to_timezone(period, name)
            end
          false ->
            {:error, "No timezone found for: #{timezone}"}
        end
      true  ->
        seconds_from_zeroyear = for |> Date.to_secs(:zero)
        [period | _] = Tzdata.periods_for_time(timezone, seconds_from_zeroyear, :wall)
        period |> tzdata_to_timezone(timezone)
    end
  end

  @doc """
  Convert a date to the given timezone.
  """
  @spec convert(date :: DateTime.t, tz :: TimezoneInfo.t) :: DateTime.t
  def convert(date, tz) do
    # Calculate the difference between `date`'s timezone, and the provided timezone
    difference = diff(date, tz)
    # Offset the provided date's time by the difference
    Date.shift(date, mins: difference) 
    |> Map.put(:timezone, tz) 
    |> Map.put(:ms, date.ms)
  end

  @doc """
  Determine what offset is required to convert a date into a target timezone
  """
  @spec diff(date :: DateTime.t, tz :: TimezoneInfo.t) :: integer
  def diff(%DateTime{:timezone => origin}, %TimezoneInfo{:offset_std => dest_std, :offset_utc => dest_utc}) do
    %TimezoneInfo{:offset_std => origin_std, :offset_utc => origin_utc} = origin
    cond do
      origin_utc == dest_utc -> dest_std - origin_std
      true -> (dest_utc + dest_std) - (origin_utc + origin_std)
    end
  end

  # Fetches the first timezone period which matches the abbreviation and is
  # valid for the given moment in time (secs from :zero)
  defp lookup_timezone_by_abbreviation(abbr, secs) do
    result = Tzdata.canonical_zone_list
    |> Stream.map(fn name -> {:ok, periods} = Tzdata.periods(name); {name, periods} end)
    |> Stream.map(fn {name, periods} ->
        p = periods |> Enum.drop_while(fn %{:from => %{:wall => from}, :until => %{:wall => until}, :zone_abbr => abbrev} ->
          cond do
            from == :min && until >= secs && abbrev == abbr -> false
            from == :min && until == :max && abbrev == abbr -> false
            from <= secs && until == :max && abbrev == abbr -> false
            from <= secs && until >= secs && abbrev == abbr -> false
            true -> true
          end
        end)
        case p do
          [x|_] -> {name, x}
          []    -> {name, nil}
        end
      end)
    |> Stream.filter(fn {_, nil} -> false; {_, _} -> true end)
    |> Enum.take(1)
    case result do
      [x] -> {:ok, x}
      []  -> {:error, :not_found}
    end
  end

  defp tzdata_to_timezone(%{from: %{standard: from}, std_off: std_off_secs, until: %{standard: until}, utc_off: utc_off_secs, zone_abbr: abbr} = _tzdata, zone) do
    start_bound = boundary_to_erlang_datetime(from)
    end_bound   = boundary_to_erlang_datetime(until)
    %TimezoneInfo{
      full_name:     zone,
      abbreviation:  abbr,
      offset_std:    trunc(std_off_secs / 60),
      offset_utc:    trunc(utc_off_secs / 60),
      from:          start_bound |> erlang_datetime_to_boundary_date,
      until:         end_bound |> erlang_datetime_to_boundary_date
    }
  end

  defp boundary_to_erlang_datetime(:min), do: :min
  defp boundary_to_erlang_datetime(:max), do: :max
  defp boundary_to_erlang_datetime(secs), do: :calendar.gregorian_seconds_to_datetime(trunc(secs))

  defp erlang_datetime_to_boundary_date(:min), do: :min
  defp erlang_datetime_to_boundary_date(:max), do: :max
  defp erlang_datetime_to_boundary_date({{y, m, d}, _} = date) do
    dow = case :calendar.day_of_the_week({y, m, d}) do
      1 -> :monday
      2 -> :tuesday
      3 -> :wednesday
      4 -> :thursday
      5 -> :friday
      6 -> :saturday
      7 -> :sunday
    end
    {dow, date}
  end

end
