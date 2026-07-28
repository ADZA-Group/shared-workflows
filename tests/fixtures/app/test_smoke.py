import os


def test_smoke_passes():
    assert 1 + 1 == 2


def test_smoke_flake():
    # SMOKE TEMP (flake radar validation): a deterministic flake — fails the first
    # attempt, then passes on the pytest-rerunfailures rerun (same-job workspace).
    # The shard ends GREEN; the flake radar must still record exactly this test.
    # Revert this function after the smoke.
    marker = os.path.join(os.path.dirname(__file__), ".flake_marker")
    if not os.path.exists(marker):
        open(marker, "w").close()
        assert False, "intentional first-attempt failure (flake radar smoke)"
    assert True
