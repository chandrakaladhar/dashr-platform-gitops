# Research Services login theme

Keycloak's login pages with the portal's look, and sign-in through an identity provider only (AAF, Google, Microsoft): no username and password form.

- Built on `keycloak.v2` (`parent` in `login/theme.properties`); only `login.ftl`, the messages and one stylesheet are ours. Everything else, including dark mode and the other pages, comes from Keycloak.
- `login/login.ftl` is `keycloak.v2`'s login page without the password form. Keycloak only shows the provider buttons when password login is on, which is why the template is overridden rather than password login switched off. **Re-check it against `keycloak.v2/login/login.ftl` when upgrading Keycloak.**
- `login/resources/css/research-services.css` holds the portal's colour tokens (base-next-js `brand/theme.css`, light and dark). Keep them in step.
- `login/resources/img/logo.png` is the portal's logo (base-next-js `brand/uni-icon.png`); `login/resources/fonts/` is Bricolage Grotesque, the portal's font (SIL Open Font License, `OFL.txt`).
- Packaged by the `configMapGenerator` in `../../kustomization.yaml` and mounted at `/opt/keycloak/themes/research-services`. Adding a file means adding it to both the generator and the volume's `items` in `../../keycloak.yaml`.
- Selected per realm in the admin console: **Realm settings → Themes → Login theme → research-services**. Use it only on realms where nobody signs in with a password (not on a test realm with a password user).
