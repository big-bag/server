{ python3Packages, fetchgit }:

python3Packages.buildPythonApplication rec {
  pname = "websockify";
  version = (import ../variables.nix).websockify_tag;

  src = fetchgit {
    url = "https://github.com/novnc/websockify.git";
    rev = (import ../variables.nix).websockify_commit_id;
    hash = (import ../variables.nix).websockify_commit_hash;
  };

  nativeBuildInputs = [
    python3Packages.pip
    python3Packages.simplejson
    python3Packages.redis
    python3Packages.jwcrypto
    python3Packages.requests
  ];

  propagatedBuildInputs = [
    python3Packages.numpy
  ];
}
