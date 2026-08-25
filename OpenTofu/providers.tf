provider "hcloud" {
  # The provider reads HCLOUD_TOKEN from the environment. Keeping credentials
  # out of variables prevents them from being serialized into plan files.
}

provider "desec" {
  # The provider reads DESEC_API_TOKEN from the environment. Its default request
  # serialization protects deSEC's per-domain API rate limits.
}
