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
