package main

# Deny base images pinned only by mutable tag (require @sha256 digest or no :latest)
deny[msg] {
    input[i].Cmd == "from"
    val := input[i].Value[0]
    contains(val, ":latest")
    msg := sprintf("base image uses mutable ':latest' tag: %s", [val])
}

# Require a non-root USER instruction
deny[msg] {
    not has_user
    msg := "Dockerfile must set a non-root USER"
}

has_user {
    input[_].Cmd == "user"
}

# Require a HEALTHCHECK
deny[msg] {
    not has_healthcheck
    msg := "Dockerfile must define a HEALTHCHECK"
}

has_healthcheck {
    input[_].Cmd == "healthcheck"
}
