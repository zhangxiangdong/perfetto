--
-- Copyright 2023 The Android Open Source Project
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

SELECT IMPORT('common.timestamps');

-- Converts a battery_stats counter value to human readable string.
--
-- @arg track STRING  The counter track name (e.g. 'battery_stats.audio').
-- @arg value FLOAT   The counter value.
-- @ret STRING        The human-readable name for the counter value.
CREATE PERFETTO FUNCTION android_battery_stats_counter_to_string(track STRING, value FLOAT)
RETURNS STRING AS
SELECT
  CASE
    WHEN ($track = "battery_stats.wifi_scan" OR
          $track = "battery_stats.wifi_radio" OR
          $track = "battery_stats.mobile_radio" OR
          $track = "battery_stats.audio" OR
          $track = "battery_stats.video" OR
          $track = "battery_stats.camera" OR
          $track = "battery_stats.power_save" OR
          $track = "battery_stats.phone_in_call")
      THEN
        CASE $value
          WHEN 0 THEN "inactive"
          WHEN 1 THEN "active"
          ELSE "unknown"
        END
    WHEN $track = "battery_stats.wifi"
      THEN
        CASE $value
          WHEN 0 THEN "off"
          WHEN 1 THEN "on"
          ELSE "unknown"
        END
    WHEN $track = "battery_stats.phone_state"
      THEN
        CASE $value
          WHEN 0 THEN "in"
          WHEN 1 THEN "out"
          WHEN 2 THEN "emergency"
          WHEN 3 THEN "off"
          ELSE "unknown"
        END
    WHEN ($track = "battery_stats.phone_signal_strength" OR
          $track = "battery_stats.wifi_signal_strength")
      THEN
        CASE $value
          WHEN 0 THEN "0/4"
          WHEN 1 THEN "1/4"
          WHEN 2 THEN "2/4"
          WHEN 3 THEN "3/4"
          WHEN 4 THEN "4/4"
          ELSE "unknown"
        END
    WHEN $track = "battery_stats.wifi_suppl"
      THEN
        CASE $value
          WHEN 0 THEN "invalid"
          WHEN 1 THEN "disconnected"
          WHEN 2 THEN "disabled"
          WHEN 3 THEN "inactive"
          WHEN 4 THEN "scanning"
          WHEN 5 THEN "authenticating"
          WHEN 6 THEN "associating"
          WHEN 7 THEN "associated"
          WHEN 8 THEN "4-way-handshake"
          WHEN 9 THEN "group-handshake"
          WHEN 10 THEN "completed"
          WHEN 11 THEN "dormant"
          WHEN 12 THEN "uninitialized"
          ELSE "unknown"
        END
    WHEN $track = "battery_stats.data_conn"
      THEN
        CASE $value
          WHEN 0 THEN "Out of service"
          WHEN 1 THEN "2.5G (GPRS)"
          WHEN 2 THEN "2.7G (EDGE)"
          WHEN 3 THEN "3G (UMTS)"
          WHEN 4 THEN "3G (CDMA)"
          WHEN 5 THEN "3G (EVDO Rel 0)"
          WHEN 6 THEN "3G (EVDO Rev A)"
          WHEN 7 THEN "3G (LXRTT)"
          WHEN 8 THEN "3.5G (HSDPA)"
          WHEN 9 THEN "3.5G (HSUPA)"
          WHEN 10 THEN "3.5G (HSPA)"
          WHEN 11 THEN "2G (IDEN)"
          WHEN 12 THEN "3G (EVDO Rev B)"
          WHEN 13 THEN "4G (LTE)"
          WHEN 14 THEN "3.5G (eHRPD)"
          WHEN 15 THEN "3.7G (HSPA+)"
          WHEN 16 THEN "2G (GSM)"
          WHEN 17 THEN "3G (TD SCDMA)"
          WHEN 18 THEN "Wifi calling (IWLAN)"
          WHEN 19 THEN "4.5G (LTE CA)"
          WHEN 20 THEN "5G (NR)"
          WHEN 21 THEN "Emergency calls only"
          WHEN 22 THEN "Other"
          ELSE "unknown"
        END
    ELSE CAST($value AS text)
  END;

-- View of human readable battery stats counter-based states. These are recorded
-- by BatteryStats as a bitmap where each 'category' has a unique value at any
-- given time.
--
-- @column ts                  Timestamp in nanoseconds.
-- @column dur                 The duration the state was active.
-- @column track_name          The name of the counter track.
-- @column value               The counter value as a number.
-- @column value_name          The counter value as a human-readable string.
CREATE VIEW android_battery_stats_state AS
SELECT
  ts,
  name AS track_name,
  CAST(value AS INT64) AS value,
  android_battery_stats_counter_to_string(name, value) AS value_name,
  IFNULL(LEAD(ts) OVER (PARTITION BY name ORDER BY ts) - ts, -1) AS dur
FROM counter
JOIN counter_track
  ON counter.track_id = counter_track.id
WHERE counter_track.name GLOB 'battery_stats.*';


-- View of slices derived from battery_stats events. Battery stats records all
-- events as instants, however some may indicate whether something started or
-- stopped with a '+' or '-' prefix. Events such as jobs, top apps, foreground
-- apps or long wakes include these details and allow drawing slices between
-- instant events found in a trace.
--
-- For example, we may see an event like the following on 'battery_stats.top':
--
--     -top=10215:"com.google.android.apps.nexuslauncher"
--
-- This view will find the associated start ('+top') with the matching suffix
-- (everything after the '=') to construct a slice. It computes the timestamp
-- and duration from the events and extract the details as follows:
--
--     track_name='battery_stats.top'
--     str_value='com.google.android.apps.nexuslauncher'
--     int_value=10215
--
-- @column track_name          The battery stats track name.
-- @column ts                  Timestamp in nanoseconds.
-- @column dur                 The duration of the event.
-- @column str_value           The string part of the event identifier.
-- @column int_value           The integer part of the event identifier.
CREATE VIEW android_battery_stats_event_slices AS
WITH
  event_markers AS (
    SELECT
      ts,
      track.name AS track_name,
      str_split(slice.name, '=', 1) AS key,
      substr(slice.name, 1, 1) = '+' AS start
    FROM slice
    JOIN track
      ON slice.track_id = track.id
    WHERE
      track_name GLOB 'battery_stats.*'
      AND substr(slice.name, 1, 1) IN ('+', '-')
  ),
  with_neighbors AS (
    SELECT
      *,
      LAG(ts) OVER (PARTITION BY track_name, key ORDER BY ts) AS last_ts,
      LEAD(ts) OVER (PARTITION BY track_name, key ORDER BY ts) AS next_ts
    FROM event_markers
  ),
  -- Note: query performance depends on the ability to push down filters on
  -- the track_name. It would be more clear below to have two queries and union
  -- them, but doing so prevents push down through the above window functions.
  event_spans AS (
    SELECT
      track_name, key,
      IIF(start, ts, trace_start()) AS ts,
      IIF(start, next_ts, ts) AS end_ts
    FROM with_neighbors
    -- For the majority of events, we take the `start` event and compute the dur
    -- based on next_ts. In the off chance we get an end event with no prior
    -- start (matched by the second half of this where), we can create an event
    -- starting from the beginning of the trace ending at the current event.
    WHERE (start OR last_ts IS NULL)
  )
SELECT
  ts,
  IFNULL(end_ts-ts, -1) AS dur,
  track_name,
  str_split(key, '"', 1) AS str_value,
  CAST(str_split(key, ':', 0) AS INT64) AS int_value
FROM event_spans;
