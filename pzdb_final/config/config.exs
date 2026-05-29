import Config

config :przma, :vault,
  base_path: System.get_env("PRZMA_LOCAL_PATH", "/tmp/przma_vaults")

# All notification payloads and attachments are stored locally under
# the vault base_path, in a subdirectory called notifications_storage/.
#
# Directory layout:
#   {base_path}/notifications_storage/{did}/notifications/inbox/{message_id}/payload.json
#   {base_path}/notifications_storage/{did}/notifications/outbox/{message_id}/payload.json
#   {base_path}/notifications_storage/{did}/notifications/attachments/{message_id}/{filename}
#
# To change the storage location, set the PRZMA_LOCAL_PATH env var.
# Example: export PRZMA_LOCAL_PATH=/var/przma/vaults
