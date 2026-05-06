# WindowPin — pin windows above other apps.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. SPM project, embedded Sparkle,
# dual-ship (.zip + .pkg).

BUNDLE_NAME      := WindowPin
BUNDLE_TYPE      := app
PRODUCT_NAME     := WindowPin.app
BUNDLE_ID        := cc.jorviksoftware.WindowPin
BUILD_SYSTEM     := spm
SPM_PRODUCT      := WindowPin

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := WindowPin.entitlements

include ../jorvik-release/release.mk
