# SMOKE TEMP (Risk-Gating validation — remove after the risky smoke is green):
# this file matches the risky default glob '**/auth*', so a dev push touching it
# must flip changes.outputs.risky=true -> light=false -> security/property/quality
# run on a dev push, with property-tests + bandit + hadolint BLOCKING.
# Deliberately bandit-clean and hypothesis-free.


def is_probe() -> bool:
    return True
