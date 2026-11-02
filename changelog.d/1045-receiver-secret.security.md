- Derive the experimental Spilman receiver key from the merchant secret using
  domain-separated HMAC-SHA256, reject invalid scalars, and make receiver-key
  regressions executable. This changes the compromised v1 receiver identity;
  settlement wiring remains incomplete.
  ([#1045](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/1045))
