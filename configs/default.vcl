vcl 4.0;
backend default {
    .host = "{{=service('balancer').getAppAlias()}}";
    .port = "{{=service('balancer').getMainPort()}}";
}
