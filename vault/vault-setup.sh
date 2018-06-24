##
# Prerequisites
# minikube
# kubectl
# helm
# vault
# This guide expects vault to be running on the local host and communicating with a local minikube. In other words,
# vault is outside the cluster
##


# Start Minikube
minikube start

# Start Vault. By default, vault will be bound to localhost interface. You have two options here. You can either
# start vault as a local server and use burp as a reverse proxy when connecting from the cluster or bind it to
# the interface of your preference with the optional parameter below.
vault server -dev [-dev-listen-address=<your_network_card_ip>]
export VAULT_ADDR='http://127.0.0.1:8200'

# Enable support to approle, vault's feature to RBAC.
vault auth enable approle

# Enable key value secret backend, use to store db credentials
vault secrets enable -version=2 kv

# Write a policy for a test app, allowing login, secret unwrap and access to a db credential under secret/data/mysql/
vault policy write base-app base-app.conf

# Creates a new role for our test application, associating the base-app policy just created. Also estipulate constraints
# to secrets (user for login) and tokens (used for api access)
vault write auth/approle/role/test-app policies=base-app secret_id_num_uses=1 secret_id_ttl=60s token_num_uses=1 token_ttl=60s
vault read auth/approle/role/test-app

# Role ID works as a username for the client application assuming the role. Logins require role-id and secret-id
vault read auth/approle/role/test-app/role-id

# This should be executed by an administrator or a independent service to give a new instance using the profile test-app 
# a secret id, which will be used to log in to vault. The wrap-ttl parameter makes vault return a single use wrapping token
# which expires in 60s, as opposed to a clear text secret id.
vault write -wrap-ttl=60s -f auth/approle/role/test-app/secret-id

# This command would be executed by a pod requiring the unwrap of its secret-id
VAULT_TOKEN=b81093b1-b3f6-c020-aa47-cb47bb7293ab vault unwrap

# Whith the role-id and secret-id, the pod can then log in and assume the associated role
vault write auth/approle/login role_id="c871bc37-9a2a-c91f-dcdb-ceb7261896f0" secret_id="00abf949-6ed2-8694-c48e-b30694f41c6d"

# And finally use the returned token to access the credentials.
VAULT_TOKEN=156cb13c-d315-26d0-da63-43d57da8a279 vault read secret/data/mysql/credential

# Joining the pieces together, let's fire the same process from a kubernetes pod. Enables kubernetes auth backend.
vault auth enable kubernetes

# This first configuration file creates a k8s service account, which will used by vault to access the JWT verification API
kubectl create -f vault-auth-sa.yml

# The second one binds the created role to the JWT review API itself
kubectl create -f vault-sa-role-binding.yml

# The next step is to grab the JWT associated to the service account (via dashboard or kubectl command) and configure vault
vault write auth/kubernetes/config token_reviewer_jwt="eyJhbGciOiJSUzI1NiIsImtpZCI6IiJ9.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9uYW1lc3BhY2UiOiJkZWZhdWx0Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZWNyZXQubmFtZSI6InZhdWx0LWF1dGgtdG9rZW4taGRxcWciLCJrdWJlcm5ldGVzLmlvL3NlcnZpY2VhY2NvdW50L3NlcnZpY2UtYWNjb3VudC5uYW1lIjoidmF1bHQtYXV0aCIsImt1YmVybmV0ZXMuaW8vc2VydmljZWFjY291bnQvc2VydmljZS1hY2NvdW50LnVpZCI6ImVkMWI1Y2YzLTc0ODAtMTFlOC04MzA0LTA4MDAyNzYzYmVkMCIsInN1YiI6InN5c3RlbTpzZXJ2aWNlYWNjb3VudDpkZWZhdWx0OnZhdWx0LWF1dGgifQ.iUEMJZTvL44N6jcjK83I-tVlAaAiFxAGPLXa_WYjG8Uhed9Y7Xjsd5ZntQguZ-NZAtKKobV_L2sc0LmRyFbbqx5BVBNBGCOQoWuv-KM1gF3W1QwWkiL6MqVMRO6RDS7DIebaUIHqSyJrm7XZ-ZZivvYF6GjuzBwQiYxn-1BXyGIBvBU1zhbBsc-MEkHIuWy2kvc9q6XkOKeIjKxkIfmoZzykfoQ9-nT8l7e1p5OTzgj2DOyt5DhS14h4gZusG-8HGquR1v8MsQo6TlrKyZ_cnas8kogJHf1DAgHwhGQjl9OZAnFaYkoW16yJDNF-6CUmAEJiCd07w3YEzxz6lt-iTw" kubernetes_host=https://192.168.99.100:8443 kubernetes_ca_cert=$HOME/.minikube/ca.crt

# The command below binds a vault role to a k8s service account, assigning to it one or more vault policies. Defining the policy
# may be irrelevant, as it was already associated before.
vault write auth/kubernetes/role/test-app bound_service_account_names=vault-auth bound_service_account_namespaces=default policies=base-app ttl=1h

# Having set up the connection between both k8s and vault, we can create the first deployment
# This first application will assume vault-auth service account and therefore vault's test-app. It does not provide
# a real security gain, as the JWT is injected to the containers of the app, allowing multiple authentication
kubectl create -f vault-auth-app-deployment.yml

# The second one is better, as it aims to create a wrapped secret that will be used once to login, receive a definitive token
# and retrieve all the secrets. It is still not ideal, as the JWTs are injected to every container, not only the init one as
# first thought. The solution for this would be break up the permissions in two roles/service accounts: vault-secret-id-generator to generate
# secret-ids for test-app roles and the secret consuming test-app. An independent deployment would then retrieve the secrets on 
# demand and inject as a volume to the init container of an application. I believe the Admission Controllers can be used for that
# more specifically: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#initializers
kubectl create -f wrapped-app-deployment.yml