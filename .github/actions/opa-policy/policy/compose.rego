package main

# Every service must declare a restart policy
deny[msg] {
    some name
    svc := input.services[name]
    not svc.restart
    msg := sprintf("compose service '%s' has no restart policy", [name])
}

# No service may use a :latest image tag
deny[msg] {
    some name
    img := input.services[name].image
    endswith(img, ":latest")
    msg := sprintf("compose service '%s' uses ':latest' image tag", [name])
}
