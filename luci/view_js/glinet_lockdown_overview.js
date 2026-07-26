'use strict';
'require view';
'require fs';

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			fs.exec('/usr/sbin/glinet-lockdown.sh', [ '--verify' ]).catch(function(err) {
				return { code: 1, stdout: '', stderr: String(err) };
			}),
			fs.read('/tmp/glinet-lockdown-gui.log').catch(function() { return 'no actions have been run from this page yet\n'; }),
			fs.read('/etc/glinet-lockdown/boot-guard.summary').catch(function() { return 'no boot guard run recorded yet\n'; }),
			fs.read('/etc/glinet-lockdown/boot-guard.log').catch(function() { return 'no boot guard log recorded yet\n'; }),
			fs.read('/etc/glinet-lockdown/optional-bundles').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/core-applied').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/latest-backup').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/dns-enforcement-enabled').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/cloud-ip-block-enabled').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/cloud-ip-blocklist').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/ssh-temp-until').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/ssh-temp-expires').catch(function() { return ''; }),
			fs.read('/etc/glinet-lockdown/fan-mode').catch(function() { return 'auto'; }),
			fs.read('/etc/glinet-lockdown/fan-pwm').catch(function() { return ''; }),
			fs.read('/etc/hosts').catch(function() { return ''; }),
			fs.read('/usr/lib/opkg/status').catch(function() { return ''; }),
			fs.exec('/etc/init.d/glinet-lockdown-guard', [ 'enabled' ]).then(function(res) {
				return res.code === 0 ? 'enabled' : 'disabled';
			}).catch(function() {
				return 'unknown';
			})
		]);
	},

	filterHostsBlock: function(hostsText) {
		var start = hostsText.indexOf('# BEGIN glinet-lockdown');
		var end = hostsText.indexOf('# END glinet-lockdown');

		if (start < 0 || end < 0 || end < start)
			return 'no lockdown blocklist found';

		return hostsText.substring(start, end + '# END glinet-lockdown'.length);
	},

	filterPackageStatus: function(statusFile) {
		var blocks = statusFile.split(/\n\n+/);
		var matches = [];

		blocks.forEach(function(block) {
			if (block.indexOf('Package: glinet-lockdown') >= 0)
				matches.push(block);
		});

		return matches.length ? matches.join('\n\n') : 'package not installed';
	},

	extractPackageSummary: function(statusFile) {
		var blocks = statusFile.split(/\n\n+/);
		var summary = 'package not installed';

		blocks.forEach(function(block) {
			var pkg = block.match(/^Package:\s*(glinet-lockdown[^\n]*)/m);
			var ver = block.match(/^Version:\s*([^\n]*)/m);

			if (pkg && ver)
				summary = pkg[1] + ' ' + ver[1];
		});

		return summary;
	},

	startSshCountdown: function(expiresEpoch, untilText) {
		var expiresMs = Number(expiresEpoch || 0) * 1000;
		var target = document.getElementById('glinet_ssh_countdown');

		if (!target || !expiresMs)
			return;

		function renderCountdown() {
			var remaining = Math.max(0, Math.floor((expiresMs - Date.now()) / 1000));
			var minutes = Math.floor(remaining / 60);
			var seconds = remaining % 60;

			if (remaining <= 0) {
				target.textContent = 'temporary SSH window has expired; disable is being enforced';
				return;
			}

			target.textContent = 'temporary SSH active: ' + minutes + 'm ' + (seconds < 10 ? '0' : '') + seconds + 's remaining' + (untilText ? ' (until ' + untilText + ')' : '');
			window.setTimeout(renderCountdown, 1000);
		}

		renderCountdown();
	},

	getSelectedOptionalCsv: function() {
		var selected = [];

		document.querySelectorAll('input[name="glinet_optional_bundle"]:checked').forEach(function(input) {
			selected.push(input.value);
		});

		return selected.join(',');
	},

	runAction: function(action) {
		var extraArgs = Array.prototype.slice.call(arguments, 1);
		var args = [];

		if (action === 'verify')
			args = [ '--verify' ];
		else if (action === 'guard')
			args = [ '--guard' ];
		else if (action !== 'run')
			args = [ action ].concat(extraArgs);

		return fs.exec_direct('/usr/sbin/glinet-lockdown.sh', args, 'text').then(function(output) {
			return fs.write('/tmp/glinet-lockdown-gui.log', output).then(function() {
				return output;
			});
		});
	},

	handleAction: function(action, ev) {
		var button = ev.currentTarget;
		var original = button.disabled;
		var confirmText = {
			'run': 'Run core lockdown now? This creates a backup, blocks GL.iNet cloud/DDNS/MQTT/rtty components, applies WAN firewall rules, and disables SSH by default.',
			'backup': 'Create a settings backup now?',
			'guard': 'Run the startup guard verification/remediation pass now?',
			'restore-latest-backup': 'Restore the latest settings backup? A pre-restore backup will be created first.',
			'refresh-cloud-ips': 'Refresh cloud IPs by resolving the configured GL.iNet cloud hostnames now?',
			'wan-scan': 'Run a local WAN exposure scan now?',
			'ssh-disable': 'Disable SSH now?'
		};

		if (confirmText[action] && !confirm(confirmText[action]))
			return Promise.resolve();

		button.disabled = true;

		return this.runAction(action).then(function() {
			window.location.reload();
		}).catch(function(err) {
			alert('Action failed: ' + err);
		}).finally(function() {
			button.disabled = original;
		});
	},

	handleOptionalSelections: function(ev) {
		var button = ev.currentTarget;
		var original = button.disabled;
		var selectionCsv = this.getSelectedOptionalCsv();

		if (!confirm('Apply optional service selections now? Checked services will be removed/enforced; unchecked services will be restored if packages are available.'))
			return Promise.resolve();

		button.disabled = true;

		return this.runAction('optional-set', selectionCsv).then(function() {
			window.location.reload();
		}).catch(function(err) {
			alert('Action failed: ' + err);
		}).finally(function() {
			button.disabled = original;
		});
	},

	handleNetworkSelections: function(ev) {
		var button = ev.currentTarget;
		var original = button.disabled;
		var dnsChoice = document.getElementById('glinet_dns_enforce').checked ? '1' : '0';

		if (!confirm('Apply network controls now? This may restart firewall and DNS services.'))
			return Promise.resolve();

		button.disabled = true;

		return this.runAction('network-set', dnsChoice).then(function() {
			window.location.reload();
		}).catch(function(err) {
			alert('Action failed: ' + err);
		}).finally(function() {
			button.disabled = original;
		});
	},

	handleProfile: function(ev) {
		var button = ev.currentTarget;
		var original = button.disabled;
		var profile = document.getElementById('glinet_profile').value;
		var selectionCsv = this.getSelectedOptionalCsv();
		var dnsChoice = document.getElementById('glinet_dns_enforce').checked ? '1' : '0';

		if (!confirm('Apply the selected profile now? Profiles run core lockdown and reconcile optional/network selections.'))
			return Promise.resolve();

		button.disabled = true;

		return this.runAction('profile', profile, selectionCsv, dnsChoice).then(function() {
			window.location.reload();
		}).catch(function(err) {
			alert('Action failed: ' + err);
		}).finally(function() {
			button.disabled = original;
		});
	},

	handleTempSsh: function(ev) {
		var button = ev.currentTarget;
		var original = button.disabled;
		var minutes = document.getElementById('glinet_ssh_minutes').value || '15';

		if (!confirm('Enable SSH temporarily? Password SSH will be enabled for the selected window, then disabled automatically.'))
			return Promise.resolve();

		button.disabled = true;

		return this.runAction('ssh-temp', minutes).then(function() {
			window.location.reload();
		}).catch(function(err) {
			alert('Action failed: ' + err);
		}).finally(function() {
			button.disabled = original;
		});
	},

	handleSelfUpdate: function(ev) {
		var self = this;
		var button = ev.currentTarget;
		var original = button.disabled;

		button.disabled = true;

		return this.runAction('update-check').then(function(output) {
			var current = (output.match(/Current version:\s*([^\n]+)/) || [])[1] || 'unknown';
			var latest = (output.match(/Latest version:\s*([^\n]+)/) || [])[1] || 'unknown';

			if (output.indexOf('UPDATE_AVAILABLE') >= 0) {
				if (confirm('Update available. Installed: ' + current + '\\nAvailable: ' + latest + '\\n\\nInstall this update now?')) {
					button.disabled = true;
					return self.runAction('self-update').then(function() {
						window.location.reload();
					});
				}
				return Promise.resolve();
			}

			if (output.indexOf('NO_UPDATE') >= 0)
				alert('No update available. Installed version: ' + current);
			else
				alert(output);
		}).catch(function(err) {
			alert('Action failed: ' + err);
		}).finally(function() {
			button.disabled = original;
		});
	},

	handleFanMode: function(ev) {
		var button = ev.currentTarget;
		var original = button.disabled;
		var mode = document.getElementById('glinet_fan_mode').value || 'auto';

		if (!confirm('Apply fan mode: ' + mode + '? Constant fan modes override the automatic fan daemon until Auto is selected again.'))
			return Promise.resolve();

		button.disabled = true;

		return this.runAction('fan', mode).then(function() {
			window.location.reload();
		}).catch(function(err) {
			alert('Action failed: ' + err);
		}).finally(function() {
			button.disabled = original;
		});
	},

	render: function(data) {
		var verifyRes = data[0];
		var lastOutput = data[1];
		var bootSummary = data[2].trim() || 'no boot guard run recorded yet';
		var bootLog = data[3];
		var optionalBundles = (data[4] || '').trim();
		var coreApplied = (data[5] || '').trim();
		var latestBackup = (data[6] || '').trim();
		var dnsEnabled = !!(data[7] || '').trim();
		var cloudIpEnabled = !!(data[8] || '').trim();
		var cloudIps = (data[9] || '').trim();
		var sshTempUntil = (data[10] || '').trim();
		var sshTempExpires = (data[11] || '').trim();
		var fanMode = (data[12] || 'auto').trim() || 'auto';
		var fanPwm = (data[13] || '').trim();
		var hostsBlock = this.filterHostsBlock(data[14]);
		var packageStatus = this.filterPackageStatus(data[15] || '');
		var packageSummary = this.extractPackageSummary(data[15] || '');
		var startupGuard = data[16];
		var verifyOutput = verifyRes.stdout || '';
		var verifySummary = (verifyOutput.trim().split('\n').pop()) || '[verify] SUMMARY: unavailable';
		var cloudIpVerified = verifyOutput.indexOf('PASS: cloud IP nft table exists') >= 0 || verifyOutput.indexOf('PASS: cloud IP blocklist file exists') >= 0;
		var cloudIpStatus = cloudIpEnabled || cloudIpVerified
			? 'enabled by core lockdown'
			: (coreApplied ? 'core applied; status file not visible to LuCI, run Verify Lockdown' : 'pending until core lockdown runs');
		var self = this;
		var selectedMap = {};
		var optionalItems = [
			{ bundle: 'tailscale', label: 'Tailscale', note: 'mesh VPN client/service' },
			{ bundle: 'zerotier', label: 'ZeroTier', note: 'mesh VPN client/service' },
			{ bundle: 'tor', label: 'Tor', note: 'Tor service and GL UI packages' },
			{ bundle: 'vpn-servers', label: 'VPN Servers', note: 'OpenVPN/WireGuard server components' },
			{ bundle: 'file-sharing', label: 'File Sharing', note: 'NAS, Samba, WebDAV, FTP, media sharing' },
			{ bundle: 'upnp-mdns', label: 'UPnP/mDNS', note: 'port mapping and local discovery' },
			{ bundle: 'adguard-parental', label: 'AdGuard/Parental', note: 'filtering and parental-control packages' },
			{ bundle: 'astrorelay', label: 'Astrorelay', note: 'Astrowarp/Astrorelay components' }
		];

		optionalBundles.split(/\s+/).forEach(function(bundle) {
			if (bundle)
				selectedMap[bundle] = true;
		});

		var fullOptionalActive = optionalBundles.split(/\s+/).indexOf('full') >= 0;
		var allOptionalSelected = optionalItems.every(function(item) {
			return fullOptionalActive || selectedMap[item.bundle];
		});
		var selectedOptionalCount = optionalItems.filter(function(item) {
			return fullOptionalActive || selectedMap[item.bundle];
		}).length;
		var customSummary = 'Custom applies the selections below: ' + selectedOptionalCount + ' optional removal' + (selectedOptionalCount === 1 ? '' : 's') + ' selected; LAN DNS enforcement ' + (dnsEnabled ? 'enabled' : 'disabled') + '.';

		function updateFullCheckbox() {
			var fullBox = document.getElementById('glinet_optional_full');
			var boxes = document.querySelectorAll('input[name="glinet_optional_bundle"]');
			var checked = 0;

			boxes.forEach(function(input) {
				if (input.checked)
					checked++;
			});

			if (fullBox)
				fullBox.checked = boxes.length > 0 && checked === boxes.length;
		}

		function optionalCheckbox(item) {
			var selected = fullOptionalActive || selectedMap[item.bundle];

			return E('div', { 'class': 'cbi-value' }, [
				E('label', {}, [
					E('input', {
						'type': 'checkbox',
						'name': 'glinet_optional_bundle',
						'value': item.bundle,
						'checked': selected ? 'checked' : null,
						'change': updateFullCheckbox
					}),
					' ',
					E('strong', {}, item.label),
					' - ',
					item.note
				])
			]);
		}

		if (sshTempExpires)
			window.setTimeout(function() {
				self.startSshCountdown(sshTempExpires, sshTempUntil);
			}, 0);

		return E('div', {}, [
			E('h2', {}, 'GL.iNet Lockdown'),
			E('p', {}, 'Apply profiles, core lockdown, optional service removals, network controls, backups, temporary SSH access, and package updates from one place.'),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Profile'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('select', { 'id': 'glinet_profile' }, [
						E('option', { 'value': 'balanced' }, 'Balanced - core lockdown only'),
						E('option', { 'value': 'strict' }, 'Strict - preset removals + DNS'),
						E('option', { 'value': 'custom', 'selected': 'selected' }, 'Custom - use selections below')
					]),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': self.handleProfile.bind(self)
					}, 'Apply Profile')
				]),
				E('p', {}, customSummary)
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Core Lockdown'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': self.handleAction.bind(self, 'run')
					}, 'Run Lockdown'),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action important',
						'click': self.handleAction.bind(self, 'verify')
					}, 'Verify Lockdown'),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': self.handleAction.bind(self, 'guard')
					}, 'Run Startup Guard')
				]),
				E('p', {}, [ 'Core status: ', E('strong', {}, coreApplied ? 'applied' : 'not applied') ])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Settings Backup'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': self.handleAction.bind(self, 'backup')
					}, 'Create Backup'),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-negative',
						'click': self.handleAction.bind(self, 'restore-latest-backup')
					}, 'Restore Latest Backup')
				]),
				E('pre', {}, latestBackup || 'no backup recorded yet')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Custom Optional Services'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('label', { 'class': 'cbi-value' }, [
						E('input', {
							'id': 'glinet_optional_full',
							'type': 'checkbox',
							'checked': allOptionalSelected ? 'checked' : null,
							'change': function(ev) {
								document.querySelectorAll('input[name="glinet_optional_bundle"]').forEach(function(input) {
									input.checked = ev.currentTarget.checked;
								});
							}
						}),
						' Full Optional Lockdown'
					])
				]),
				E('div', { 'class': 'cbi-section-node' }, optionalItems.map(optionalCheckbox)),
				E('div', { 'class': 'cbi-section-node' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': self.handleOptionalSelections.bind(self)
					}, 'Execute Optional Selections')
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Custom Network Controls'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('label', { 'class': 'cbi-value' }, [
						E('input', {
							'id': 'glinet_dns_enforce',
							'type': 'checkbox',
							'checked': dnsEnabled ? 'checked' : null
						}),
						' Enforce LAN DNS through router'
					]),
					E('p', {}, [ 'Known GL.iNet cloud IP blocking: ', E('strong', {}, cloudIpStatus) ])
				]),
				E('div', { 'class': 'cbi-section-node' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': self.handleNetworkSelections.bind(self)
					}, 'Apply Network Controls'),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': self.handleAction.bind(self, 'refresh-cloud-ips')
					}, 'Refresh Cloud IPs'),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action important',
						'click': self.handleAction.bind(self, 'wan-scan')
					}, 'WAN Exposure Scan')
				]),
				E('pre', {}, 'Known blocked GL.iNet/GoodCloud IP denylist\nThese are intentionally blocked destinations, not observed router connections.\n\n' + (cloudIps || 'no cloud IP denylist entries recorded yet'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Temporary SSH Access'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('input', {
						'id': 'glinet_ssh_minutes',
						'type': 'number',
						'min': '1',
						'max': '240',
						'value': '15',
						'style': 'width: 6em'
					}),
					' minutes ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': self.handleTempSsh.bind(self)
					}, 'Enable SSH Temporarily'),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-negative',
						'click': self.handleAction.bind(self, 'ssh-disable')
					}, 'Disable SSH Now')
				]),
				E('pre', { 'id': 'glinet_ssh_countdown' }, sshTempUntil ? ('temporary SSH active: calculating time remaining...') : 'temporary SSH is not active')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Fan Control'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('select', { 'id': 'glinet_fan_mode' }, [
						E('option', { 'value': 'auto', 'selected': fanMode === 'auto' ? 'selected' : null }, 'Auto'),
						E('option', { 'value': 'off', 'selected': fanMode === 'off' ? 'selected' : null }, 'Off'),
						E('option', { 'value': 'low', 'selected': fanMode === 'low' ? 'selected' : null }, 'Low'),
						E('option', { 'value': 'medium', 'selected': fanMode === 'medium' ? 'selected' : null }, 'Medium'),
						E('option', { 'value': 'high', 'selected': fanMode === 'high' ? 'selected' : null }, 'High')
					]),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': self.handleFanMode.bind(self)
					}, 'Apply Fan Mode')
				]),
				E('pre', {}, 'mode: ' + fanMode + (fanPwm ? '\\nPWM: ' + fanPwm : ''))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Update'),
				E('p', {}, [ 'Installed: ', E('strong', {}, packageSummary) ]),
				E('div', { 'class': 'cbi-section-node' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': self.handleSelfUpdate.bind(self)
					}, 'Check for Update')
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Enforced Optional Removals'),
				fullOptionalActive ? E('div', { 'class': 'alert-message success' }, 'Full optional lockdown has been applied and will be enforced by the startup guard.') : '',
				E('pre', {}, optionalBundles || 'none selected')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Package Status'),
				E('pre', {}, packageStatus)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Last Verification Summary'),
				E('pre', {}, verifySummary)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Startup Guard'),
				E('p', {}, [ 'Status: ', E('strong', {}, startupGuard) ]),
				E('pre', {}, bootSummary)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Current Host Blocklist'),
				E('pre', {}, hostsBlock)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Last Action Output'),
				E('pre', {}, lastOutput)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Last Startup Guard Log'),
				E('pre', {}, bootLog)
			])
		]);
	}
});
