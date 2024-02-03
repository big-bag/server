{
  stdenv,
  pkgs,
  lib,
  script_name,
  script_path
}:

stdenv.mkDerivation rec {
  name = script_name;

  src = builtins.path {
    path = ../scripts/.;
  };

  phases = [ "installPhase" ];

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp $src/${name}.sh $out/bin/${name}.sh
    chmod +x $out/bin/${name}.sh
    wrapProgram $out/bin/${name}.sh --prefix PATH : ${lib.makeBinPath script_path}
  '';
}
