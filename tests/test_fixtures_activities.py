"""Step 3 of v0.5: the ACTIVITIES fixture and FakeGarmin.get_activities
plumbing, ahead of build_activity/build_activities existing (step 4) —
cmd_fetch does not call get_activities yet at this point in the sequence.
"""
import fixtures


def test_fake_garmin_get_activities_records_the_call(fake_garmin):
    fake_garmin.activities = fixtures.ACTIVITIES
    g = fake_garmin()
    got = g.get_activities(0, 20)
    assert got == fixtures.ACTIVITIES
    assert ("get_activities", (0, 20)) in fake_garmin.calls


def test_activities_fixture_has_three_entries_with_hostile_fields():
    assert len(fixtures.ACTIVITIES) == 3
    for a in fixtures.ACTIVITIES:
        assert "startLatitude" in a and "ownerFullName" in a
        assert "locationName" in a and "deviceId" in a and "hasPolyline" in a


def test_activities_dict_form_wraps_the_same_list():
    assert fixtures.ACTIVITIES_DICT_FORM["activityList"] == fixtures.ACTIVITIES
