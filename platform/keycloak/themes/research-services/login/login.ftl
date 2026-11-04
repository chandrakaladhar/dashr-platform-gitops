<#--
  Research Services: sign in only through an identity provider (AAF, Google,
  Microsoft). Based on keycloak.v2's login.ftl (Keycloak 26.8) without the
  username and password form. keycloak.v2 shows the provider buttons only when
  realm.password is on, so this template shows them whatever it says. Nobody
  in the realm has a password, so the password step behind it can't sign
  anyone in. Re-check against keycloak.v2's login.ftl when upgrading Keycloak.
-->
<#import "template.ftl" as layout>
<#import "social-providers.ftl" as identityProviders>
<@layout.registrationLayout displayMessage=true displayInfo=false; section>
<!-- template: login.ftl (research-services) -->
    <#if section = "header">
        ${msg("loginAccountTitle")}
    <#elseif section = "form">
        <#if social.providers?? && social.providers?has_content>
            <p id="rs-login-intro">${msg("rsLoginIntro")}</p>
        <#else>
            <p id="rs-login-intro">${msg("rsNoProviders")}</p>
        </#if>
    <#elseif section = "socialProviders">
        <#if social.providers?? && social.providers?has_content>
            <@identityProviders.show social=social/>
        </#if>
    </#if>
</@layout.registrationLayout>
