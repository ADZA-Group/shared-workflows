package main

# conftest evaluates EVERY .rego in the policy dir against EVERY input, so the
# Dockerfile-only rules below must be guarded to not fire on compose/other YAML.
is_dockerfile {
    input[_].Cmd
}

# Deny base images pinned only by mutable tag (require @sha256 digest or no :latest)
deny[msg] {
    input[i].Cmd == "from"
    val := input[i].Value[0]
    contains(val, ":latest")
    msg := sprintf("base image uses mutable ':latest' tag: %s", [val])
}

# Require a non-root USER instruction
deny[msg] {
    is_dockerfile
    not has_user
    msg := "Dockerfile must set a non-root USER"
}

has_user {
    input[_].Cmd == "user"
}

# Require a HEALTHCHECK
deny[msg] {
    is_dockerfile
    not has_healthcheck
    msg := "Dockerfile must define a HEALTHCHECK"
}

has_healthcheck {
    input[_].Cmd == "healthcheck"
}
