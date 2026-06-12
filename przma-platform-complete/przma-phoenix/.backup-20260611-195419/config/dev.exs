

# Linode Object Storage endpoint
config :ex_aws, :s3,
  scheme: "https://",
  host: "in-maa-1.linodeobjects.com",
  region: "in-maa-1",
  port: 443

config :ex_aws,
  access_key_id: {:system, "QBQ24J1P1BV957AUYYXV"},
  secret_access_key: {:system, "LqqbMn1gBggICrvrqQMOKQ57T9rnqeXXOx6x8H7B"}
