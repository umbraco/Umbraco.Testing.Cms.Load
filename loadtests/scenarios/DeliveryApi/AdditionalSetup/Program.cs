// Program.cs overlay for the DeliveryApi scenario.
//
// Modern Umbraco's Delivery API needs BOTH an appsettings flag AND a code-side
// builder registration. The appsettings overlay (AdditionalSetup/appsettings.json)
// flips the feature on; this Program.cs adds .AddDeliveryApi() so the DI services
// behind the API endpoints (IRequestSegmentService and friends) are registered.
// Without this, hitting /umbraco/delivery/api/v2/content returns 500 with
// "Unable to resolve service for type 'IRequestSegmentService'".
//
// The rest of this file mirrors the default `dotnet new umbraco` Program.cs —
// the install script overwrites the template-generated Program.cs with this one,
// so anything not here is dropped. Keep in sync with v17's template shape.

WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

builder.CreateUmbracoBuilder()
    .AddBackOffice()
    .AddWebsite()
    .AddDeliveryApi()
    .AddComposers()
    .Build();

WebApplication app = builder.Build();

await app.BootUmbracoAsync();

app.UseUmbraco()
    .WithMiddleware(u =>
    {
        u.UseBackOffice();
        u.UseWebsite();
    })
    .WithEndpoints(u =>
    {
        // v17 dropped UseInstallerEndpoints() from the endpoint builder context;
        // the installer routes are now part of UseBackOfficeEndpoints().
        u.UseBackOfficeEndpoints();
        u.UseWebsiteEndpoints();
    });

await app.RunAsync();
