include $(TOPDIR)/rules.mk

PKG_NAME:=portal-dns-guard
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/portal-dns-guard
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Captive-portal-aware dnsmasq upstream controller
  DEPENDS:=+dnsmasq-full +dnsproxy +bind-dig +jsonfilter +ubus +uclient-fetch +ca-bundle
endef

define Package/portal-dns-guard/description
  Keeps dnsmasq fail-closed on dnsproxy after login while allowing a bounded
  WAN-DNS grace window for captive portal authentication.
endef

define Package/portal-dns-guard/conffiles
/etc/config/portal-dns-guard
endef

define Package/portal-dns-guard/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/portal-dns-guard.config $(1)/etc/config/portal-dns-guard
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/portal-dns-guard.init $(1)/etc/init.d/portal-dns-guard
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/95-portal-dns-guard.hotplug $(1)/etc/hotplug.d/iface/95-portal-dns-guard
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-portal-dns-guard.defaults $(1)/etc/uci-defaults/99-portal-dns-guard
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/portal-dns-guard.sh $(1)/usr/sbin/portal-dns-guard
endef

$(eval $(call BuildPackage,portal-dns-guard))
