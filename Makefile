PREFIX ?= /usr/local
SBINDIR = $(PREFIX)/sbin
VERSION = 0.2.0
DEB = build/p3-fancurve_$(VERSION)_all.deb

.PHONY: install uninstall deb clean

install:
	install -Dm755 p3-fancurve $(DESTDIR)$(SBINDIR)/p3-fancurve
	install -Dm644 p3-fancurve.default $(DESTDIR)/etc/default/p3-fancurve
	install -d $(DESTDIR)/etc/systemd/system $(DESTDIR)/etc/modules-load.d
	sed 's|@SBINDIR@|$(SBINDIR)|' systemd/p3-fancurve.service > $(DESTDIR)/etc/systemd/system/p3-fancurve.service
	echo acpi_call > $(DESTDIR)/etc/modules-load.d/p3-fancurve.conf
	@[ -n "$(DESTDIR)" ] || { systemctl daemon-reload; echo "now: systemctl enable --now p3-fancurve"; }

uninstall:
	-systemctl disable --now p3-fancurve
	rm -f $(SBINDIR)/p3-fancurve /etc/systemd/system/p3-fancurve.service /etc/modules-load.d/p3-fancurve.conf
	systemctl daemon-reload
	@echo "kept /etc/default/p3-fancurve"

deb:
	rm -rf build/pkg && mkdir -p build/pkg/DEBIAN
	install -Dm755 p3-fancurve build/pkg/usr/sbin/p3-fancurve
	install -Dm644 p3-fancurve.default build/pkg/etc/default/p3-fancurve
	install -d build/pkg/lib/systemd/system build/pkg/usr/lib/modules-load.d
	sed 's|@SBINDIR@|/usr/sbin|' systemd/p3-fancurve.service > build/pkg/lib/systemd/system/p3-fancurve.service
	echo acpi_call > build/pkg/usr/lib/modules-load.d/p3-fancurve.conf
	sed 's|@VERSION@|$(VERSION)|' debian/control > build/pkg/DEBIAN/control
	install -m755 debian/postinst debian/prerm debian/postrm build/pkg/DEBIAN/
	echo /etc/default/p3-fancurve > build/pkg/DEBIAN/conffiles
	dpkg-deb --root-owner-group --build build/pkg $(DEB)

clean:
	rm -rf build
