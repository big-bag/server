{ stdenv, fetchurl }:

stdenv.mkDerivation rec {
  name = "nginx-prometheus-exporter";
  version = (import ../variables.nix).nginx_prometheus_exporter_tag;

  src = fetchurl {
    url = "https://github.com/nginxinc/${name}/releases/download/v${version}/${name}_${version}_linux_amd64.tar.gz";
    hash = (import ../variables.nix).nginx_prometheus_exporter_release_hash;
  };
  sourceRoot = ".";

  installPhase = "install -m755 -D ${name} $out/bin/${name}";
}
