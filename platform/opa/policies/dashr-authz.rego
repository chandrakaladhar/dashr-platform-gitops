# Example application authorization policy, queried by dashr-nova at
#   POST /v1/data/dashr/authz/allow   {"input": {...}}
# Replace with your real rules, or load bundles from a bundle server.
package dashr.authz

default allow := false

allow if "platform-admin" in input.user.roles

allow if {
	input.action == "read"
	"researcher" in input.user.roles
}
