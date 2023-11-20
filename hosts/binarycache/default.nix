# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
#
# SPDX-License-Identifier: Apache-2.0
{
  self,
  inputs,
  lib,
  config,
  ...
}: {
  sops.defaultSopsFile = ./secrets.yaml;
  sops.secrets.cache-sig-key.owner = "root";

  imports = lib.flatten [
    (with inputs; [
      nix-serve-ng.nixosModules.default
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ])
    (with self.nixosModules; [
      common
      qemu-common
      service-openssh
      service-binary-cache
      service-nginx
      user-jrautiola
      user-cazfi
      user-hydra
    ])
    ./disk-config.nix
  ];

  nix.settings = {
    # we don't want the cache to be a substitutor for itself
    substituters = lib.mkForce ["https://cache.nixos.org/"];
    trusted-users = ["hydra"];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  services.openssh.enable = true;

  boot.loader.grub = {
    enable = true;
    # qemu vms are using SeaBIOS which is not UEFI
    efiSupport = false;
  };

  networking = {
    hostName = "binarycache";
    nameservers = ["1.1.1.1" "8.8.8.8"];
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "trash@unikie.com";
  };

  services.nginx = {
    virtualHosts = {
      "cache.vedenemo.dev" = {
        enableACME = true;
        forceSSL = true;
        default = true;
        locations."/" = {
          proxyPass = "http://${config.services.nix-serve.bindAddress}:${toString config.services.nix-serve.port}";
        };
      };
    };
  };
}
