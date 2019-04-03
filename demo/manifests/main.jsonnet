local kube = import './vendor/kube-prod-runtime/lib/kube.libsonnet';

local cert_manager = import './vendor/kube-prod-runtime/components/cert-manager.jsonnet';
local externaldns = import './vendor/kube-prod-runtime/components/externaldns.jsonnet';

local contour = import './components/contour.jsonnet';
local dex = import './components/dex.jsonnet';
local gangway = import './components/gangway.jsonnet';

local config = import './config.json';

local namespace = 'auth';

local IngressRouteTLSPassthrough(namespace, name, domain, serviceName, servicePort) = contour.IngressRoute(
  namespace,
  name,
) {
  spec+: {
    virtualhost: {
      fqdn: domain,
      tls: {
        passthrough: true,
      },
    },
    tcpproxy: {
      services: [
        {
          name: serviceName,
          port: 5556,
        },
      ],
    },
    routes: [
      {
        match: '/',
        services: [
          {
            name: 'fake',
            port: 6666,
          },
        ],
      },
    ],
  },
};

{
  config:: config,

  base_domain:: error 'base_domain is undefined',

  cert_manager: cert_manager {
    google_secret: kube.Secret($.cert_manager.p + 'clouddns-google-credentials') + $.cert_manager.metadata {
      data_+: {
        'credentials.json': $.config.cert_manager.service_account_credentials,
      },
    },

    metadata:: {
      metadata+: {
        namespace: 'kube-system',
      },
    },
    letsencrypt_contact_email:: 'simon+letsencrypt@swine.de',
    letsencrypt_environment:: 'prod',

    letsencryptStaging+: {
      spec+: {
        acme+: {
          http01: null,
          dns01: {
            providers: [{
              name: 'clouddns',
              clouddns: {
                project: $.config.cert_manager.project,
                serviceAccountSecretRef: {
                  name: $.cert_manager.google_secret.metadata.name,
                  key: 'credentials.json',
                },
              },
            }],
          },
        },
      },
    },
  },

  cert_manager_google_issuer: cert_manager.Issuer('clouddns') {
  },

  externaldns: externaldns {
    metadata:: {
      metadata+: {
        namespace: 'kube-system',
      },
    },

    gcreds: kube.Secret($.externaldns.p + 'externaldns-google-credentials') + $.externaldns.metadata {
      data_+: {
        'credentials.json': $.config.externaldns.service_account_credentials,
      },
    },

    deploy+: {
      ownerId: $.base_domain,
      spec+: {
        template+: {
          spec+: {
            volumes_+: {
              gcreds: kube.SecretVolume($.externaldns.gcreds),
            },
            containers_+: {
              edns+: {
                args_+: {
                  provider: 'google',
                  'google-project': $.config.externaldns.project,
                },
                env_+: {
                  GOOGLE_APPLICATION_CREDENTIALS: '/google/credentials.json',
                },
                volumeMounts_+: {
                  gcreds: { mountPath: '/google', readOnly: true },
                },
              },
            },
          },
        },
      },
    },
  },

  namespace: kube.Namespace(namespace),

  contour: contour {
    base_domain:: $.base_domain,

    metadata:: {
      metadata+: {
        namespace: namespace,
      },
    },
  },

  dex: dex {
    local this = self,
    namespace:: namespace,
    base_domain:: $.base_domain,

    ingressRoute: IngressRouteTLSPassthrough(namespace, this.app, this.domain, this.app, 5556),
  },

  dexPasswordChristian: dex.Password('christian', 'simon@swine.de', '$2y$10$i2.tSLkchjnpvnI73iSW/OPAVriV9BWbdfM6qemBM1buNRu81.ZG.'),  // plaintext: secure

  gangway: gangway {
    local this = self,
    base_domain:: $.base_domain,
    metadata:: {
      metadata+: {
        namespace: namespace,
      },
    },
    ingressRoute: IngressRouteTLSPassthrough(namespace, this.app, this.domain, this.app, 8080),
  },

}