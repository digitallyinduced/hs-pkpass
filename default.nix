{ mkDerivation, aeson, attoparsec, base, binary, bytestring
, conduit, conduit-extra, directory, lib, old-locale, random
, resourcet, scientific, shakespeare, shakespeare-text, shelly
, system-filepath, text, time, transformers, unordered-containers
, uuid, zip-archive
}:
mkDerivation {
  pname = "hs-pkpass";
  version = "0.5";
  src = ./.;
  libraryHaskellDepends = [
    aeson attoparsec base binary bytestring conduit conduit-extra
    directory old-locale random resourcet scientific shakespeare
    shakespeare-text shelly system-filepath text time transformers
    unordered-containers uuid zip-archive
  ];
  homepage = "https://github.com/tazjin/hs-pkpass";
  description = "A library for Passbook pass creation & signing";
  license = lib.licenses.bsd3;
}
