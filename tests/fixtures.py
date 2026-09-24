"""Response shapes for garminconnect 0.3.11.

Modeled on real Garmin Connect response shapes; values synthesized. No account
or device ids, no owner names or profile URLs, no GPS coordinates. Values are
kept realistic (and the array column layouts kept exactly) because the whole
point of these fixtures is that the parsing code is written against what the
API actually returns, not against what the docs imply.
"""

T0 = 1787382000000          # local midnight, epoch ms
MIN = 60_000


def _row(i, val, step_min=3):
    return [T0 + i * step_min * MIN, val]


# --- get_body_battery(today) -------------------------------------------------
# A *list* of per-day dicts. Its bodyBatteryValuesArray is sparse: the real
# account returned six points for a full day (they read like inflection
# markers, not a curve).
BODY_BATTERY = [{
    "date": "2026-08-22",
    "charged": 58,
    "drained": 47,
    "startTimestampLocal": "2026-08-22T00:00:00.0",
    "endTimestampLocal": "2026-08-22T20:03:00.0",
    "bodyBatteryValueDescriptorDTOList": [
        {"bodyBatteryValueDescriptorIndex": 0,
         "bodyBatteryValueDescriptorKey": "timestamp"},
        {"bodyBatteryValueDescriptorIndex": 1,
         "bodyBatteryValueDescriptorKey": "bodyBatteryLevel"},
    ],
    "bodyBatteryValuesArray": [
        [T0, 14], [T0 + 23940000, 61], [T0 + 29880000, 77],
        [T0 + 47700000, 53], [T0 + 48240000, 52], [T0 + 70740000, 25],
    ],
}]

# --- get_stress_data(today) --------------------------------------------------
# 401 three-minute samples for a full day. stressLevel is -1 (and sometimes -2)
# whenever the watch had no valid reading — those rows must be dropped, not
# plotted as negative stress. The same payload also carries a *dense* body
# battery array, four columns wide.
_STRESS_PATTERN = [56, 38, 43, 49, 41, -1, 38, 27, 61, 30, -1, 22, 79, 45, 18]
STRESS = {
    "calendarDate": "2026-08-22",
    "startTimestampLocal": "2026-08-22T00:00:00.0",
    "endTimestampLocal": "2026-08-22T20:03:00.0",
    "maxStressLevel": 96,
    "avgStressLevel": 30,
    "stressValueDescriptorsDTOList": [
        {"index": 0, "key": "timestamp"},
        {"index": 1, "key": "stressLevel"},
    ],
    "stressValuesArray": [
        _row(i, _STRESS_PATTERN[i % len(_STRESS_PATTERN)]) for i in range(401)
    ],
    "bodyBatteryValueDescriptorsDTOList": [
        {"bodyBatteryValueDescriptorIndex": 0,
         "bodyBatteryValueDescriptorKey": "timestamp"},
        {"bodyBatteryValueDescriptorIndex": 1,
         "bodyBatteryValueDescriptorKey": "bodyBatteryStatus"},
        {"bodyBatteryValueDescriptorIndex": 2,
         "bodyBatteryValueDescriptorKey": "bodyBatteryLevel"},
        {"bodyBatteryValueDescriptorIndex": 3,
         "bodyBatteryValueDescriptorKey": "bodyBatteryVersion"},
    ],
    "bodyBatteryValuesArray": [
        [T0 + i * 3 * MIN, "MEASURED", 11 + (i % 64), 3.0] for i in range(401)
    ],
}

# --- get_hrv_data(today) -----------------------------------------------------
HRV = {
    "hrvSummary": {
        "calendarDate": "2026-08-22",
        "weeklyAvg": 44,
        "lastNightAvg": 58,
        "lastNight5MinHigh": 82,
        "baseline": {"lowUpper": 40, "balancedLow": 44, "balancedUpper": 63},
        "status": "BALANCED",
        "feedbackPhrase": "HRV_BALANCED_8",
    },
    "hrvReadings": [{"hrvValue": 29, "readingTimeLocal": "2026-08-21T23:21:47.0"}],
}

# --- get_training_readiness(today) -------------------------------------------
# A *list*; the current reading is the first element.
READINESS = [{
    "calendarDate": "2026-08-22",
    "level": "MODERATE",
    "score": 54,
    "sleepScore": 52,
    "feedbackShort": "BOOSTED_BY_LIGHTER_TRAINING",
    "recoveryTime": 160,
}]

# --- get_intensity_minutes_data(today) ---------------------------------------
INTENSITY = {
    "calendarDate": "2026-08-22",
    "weeklyModerate": 5,
    "weeklyVigorous": 8,
    "weeklyTotal": 21,
    "weekGoal": 150,
    "moderateMinutes": 1,
    "vigorousMinutes": 3,
    "imValueDescriptorsDTOList": [{"index": 0, "key": "timestamp"},
                                  {"index": 1, "key": "value"}],
    "imValuesArray": [[T0 + 53099999, 7]],
}

# --- get_last_activity() -----------------------------------------------------
# Coordinates, ids, owner name and profile image URLs deliberately removed:
# nothing from this dict reaches the payload except type/duration/distance/date.
LAST_ACTIVITY = {
    "activityType": {"typeId": 3, "typeKey": "hiking", "parentTypeId": 17},
    "startTimeLocal": "2026-01-15",
    "distance": 12000.0,
    "duration": 6400.0,
}


# --- ranged (week) endpoints, probed 2026-09-05 --------------------------------
#
# Dates are generated relative to today because the helper asks for
# today-6..today; the shapes are exact, the values synthesized. A `back` of 0
# is today, 1 is yesterday. Sources deliberately disagree with SUMMARY/SLEEP
# for today so the merge-precedence tests can tell them apart.
import datetime as _dt


def day(back):
    return (_dt.date.today() - _dt.timedelta(days=back)).isoformat()


def week_steps(backs=range(6, -1, -1)):
    # get_daily_steps(start, end)
    return [{"calendarDate": day(b), "totalSteps": 5000 + b * 100,
             "totalDistance": 4000 + b * 80, "stepGoal": 8000 + b * 10}
            for b in backs]


def week_rhr(backs=range(6, -1, -1)):
    # get_rhr_daily(start, end) — value is a float; days without a reading are absent
    return [{"calendarDate": day(b), "value": 50.0 + b} for b in backs]


def week_sleep(backs=range(6, -1, -1)):
    # get_sleep_daily(start, end) — stage times in SECONDS; unworn nights absent
    return [{"calendarDate": day(b), "values": {
        "sleepScore": 60 + b, "totalSleepTimeInSeconds": 6 * 3600 + b * 60,
        "deepTime": 3600 + b * 60, "lightTime": 4 * 3600, "remTime": 1800,
        "awakeTime": 600, "restingHeartRate": 50 + b, "avgOvernightHrv": 40 + b,
        "spO2": 94.5, "respiration": 15.2, "hrvStatus": "BALANCED",
        "bodyBatteryChange": 40, "sleepScoreQuality": "FAIR"}} for b in backs]


def week_body_battery(backs=range(6, -1, -1)):
    # get_body_battery(start, end) — keyed `date`; the values array is sparse
    # and can open with null readings that must not become the day's low
    return [{"date": day(b), "charged": 40 + b, "drained": 30 + b,
             "startTimestampLocal": day(b) + "T00:00:00.0",
             "endTimestampLocal": day(b) + "T23:59:00.0",
             "bodyBatteryValueDescriptorDTOList": [
                 {"bodyBatteryValueDescriptorIndex": 0,
                  "bodyBatteryValueDescriptorKey": "timestamp"},
                 {"bodyBatteryValueDescriptorIndex": 1,
                  "bodyBatteryValueDescriptorKey": "bodyBatteryLevel"}],
             "bodyBatteryValuesArray": [[T0, None], [T0 + MIN, 20 + b],
                                        [T0 + 2 * MIN, 70 + b], [T0 + 3 * MIN, 35]]}
            for b in backs]


def week_hrv(backs=range(6, -1, -1)):
    # get_hrv_data_range(start, end) — a dict wrapping the per-day list;
    # lastNightAvg is null on a night the watch was off
    return {"userProfilePk": 0, "hrvSummaries": [
        {"calendarDate": day(b), "weeklyAvg": 44, "lastNightAvg": 50 + b,
         "lastNight5MinHigh": 80,
         "baseline": {"lowUpper": 40, "balancedLow": 44, "balancedUpper": 63,
                      "markerValue": 0.47},
         "status": "BALANCED", "feedbackPhrase": "HRV_BALANCED_8"} for b in backs]}


def week_calories(backs=range(6, -1, -1)):
    # get_calories_daily(start, end)
    return [{"calendarDate": day(b), "active": 300.0 + b, "resting": 1600.0,
             "total": 1900.0 + b} for b in backs]


# --- get_activities(0, ACTIVITY_LIMIT) ---------------------------------------
# Probed 2026-09-24 (garminconnect 0.3.11, get_activities(0, 3)): a bare
# list[dict], startTimeLocal/startTimeGMT as "YYYY-MM-DD HH:MM:SS" (space
# separator, seconds present), duration/distance/averageHR/maxHR/calories/
# elevationGain/averageSpeed all float. Every value below is invented — ids,
# names, timestamps, distances, HR, owner/device/location — nothing here was
# copied from that probe (see docs/implementation-notes-v5.md, gitignored,
# for the field-name/type findings). The hostile fields (coordinates, owner
# name/ids/profile images, device id, locationName, timeZoneId, polyline
# flag, split summaries) are included with invented values on purpose: the
# whitelist test proves build_activity drops every one of them.
def _activity(back, hour, activity_id, type_key, name, duration_s, distance_m,
             avg_hr=None, max_hr=None, kcal=None, elev_m=None, avg_speed=None):
    local = f"{day(back)} {hour:02d}:14:33"
    gmt = f"{day(back)} {(hour + 7) % 24:02d}:14:33"   # invented UTC offset
    return {
        "activityId": activity_id,
        "activityUUID": {"uuid": f"11111111-0000-0000-0000-{activity_id:012d}"},
        "activityName": name,
        "activityType": {"typeId": 1, "typeKey": type_key, "parentTypeId": 17,
                         "isHidden": False, "restricted": False, "trimmable": True},
        "startTimeLocal": local,
        "startTimeGMT": gmt,
        "duration": duration_s,
        "distance": distance_m,
        "averageHR": avg_hr,
        "maxHR": max_hr,
        "calories": kcal,
        "elevationGain": elev_m,
        "averageSpeed": avg_speed,
        # hostile / never-kept fields, invented values throughout:
        "startLatitude": 10.0 + back,
        "startLongitude": -20.0 - back,
        "endLatitude": 10.1 + back,
        "endLongitude": -20.1 - back,
        "locationName": "Nowhereville",
        "ownerId": 900000001,
        "ownerDisplayName": "demo.user",
        "ownerFullName": "Demo User",
        "ownerProfileImageUrlSmall": "https://example.invalid/s.jpg",
        "ownerProfileImageUrlMedium": "https://example.invalid/m.jpg",
        "ownerProfileImageUrlLarge": "https://example.invalid/l.jpg",
        "deviceId": 800000001 + back,
        "timeZoneId": 55,   # invented; deliberately not the account's real tz id
        "hasPolyline": True,
        "hasSplits": True,
        "splitSummaries": [{"distance": 1000.0, "duration": 300.0}],
        "manufacturer": "GARMIN",
        "privacy": {"typeKey": "public"},
        "userRoles": ["ROLE_CONNECTUSER"],
    }


ACTIVITIES = [
    _activity(1, 7, 10000000001, "running", "Morning Run", 3120.0, 8410.0,
             avg_hr=143, max_hr=171, kcal=512, elev_m=86),
    _activity(3, 17, 10000000002, "road_biking", "Evening Ride", 5400.0, 32000.0,
             avg_hr=128, max_hr=160, kcal=780, elev_m=210, avg_speed=5.93),
    _activity(6, 9, 10000000003, "hiking", "Trailhead Loop", 6420.0, 0.0),
]

ACTIVITIES_DICT_FORM = {"activityList": ACTIVITIES}


def week_stress(backs=range(6, -1, -1)):
    # connectapi("/usersummary-service/stats/stress/daily/{start}/{end}") —
    # durations in SECONDS
    return [{"calendarDate": day(b), "values": {
        "overallStressLevel": 25 + b, "restStressDuration": 36000,
        "lowStressDuration": 7200 + b * 60, "mediumStressDuration": 3600,
        "highStressDuration": 1800}} for b in backs]
