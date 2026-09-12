import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/derogold_logo.dart';

/// Keep in step with `version:` in pubspec.yaml.
const _kVersion = '1.0.0';
const _kGithubUrl = 'https://github.com/derogold/derogold-core';
const _kWebsiteUrl = 'https://derogold.com/';
const _kBlueskyUrl = 'https://bsky.app/profile/derogold.bsky.social';
const _kTwitterUrl = 'https://twitter.com/DeroGold';
const _kRedditUrl = 'https://reddit.com/r/DeroGold';
const _kMediumUrl = 'https://medium.com/@DeroGold';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: SizedBox(
          width: 500,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              const DeroGoldLogo(size: 56),
              const SizedBox(height: 16),
              Text(tr?.appTitle ?? 'DeroGold Wallet', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(tr?.versionInfo(_kVersion) ?? 'Version $_kVersion — DEGO Desktop Wallet',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 32),

              // Description card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr?.aboutTitle ?? 'About', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 10),
                      Text(
                        tr?.aboutDescription ??
                        'DeroGold Wallet is the official desktop wallet for DeroGold (DEGO), '
                        'a fast and lightweight CryptoNote-based cryptocurrency.\n\n'
                        'Built with Flutter, powered by wallet_capi.',
                        style: const TextStyle(height: 1.6),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Links card
              Card(
                child: Column(
                  children: [
                    _LinkTile(
                      icon: Icons.code,
                      label: tr?.github ?? 'GitHub',
                      subtitle: tr?.githubSubtitle ?? 'View source code and releases',
                      url: _kGithubUrl,
                      onTap: () => _open(_kGithubUrl),
                    ),
                    const Divider(height: 1, indent: 56),
                    _LinkTile(
                      icon: Icons.language,
                      label: tr?.website ?? 'Website',
                      subtitle: tr?.websiteSubtitle ?? 'derogold.com',
                      url: _kWebsiteUrl,
                      onTap: () => _open(_kWebsiteUrl),
                    ),
                    const Divider(height: 1, indent: 56),
                    // No l10n keys for these three: they are proper nouns and
                    // the handle underneath is the same in every language.
                    _LinkTile(
                      icon: Icons.cloud_outlined,
                      label: 'Bluesky',
                      subtitle: '@derogold.bsky.social',
                      url: _kBlueskyUrl,
                      onTap: () => _open(_kBlueskyUrl),
                    ),
                    const Divider(height: 1, indent: 56),
                    _LinkTile(
                      icon: Icons.alternate_email,
                      label: tr?.twitterX ?? 'Twitter / X',
                      subtitle: '@DeroGold',
                      url: _kTwitterUrl,
                      onTap: () => _open(_kTwitterUrl),
                    ),
                    const Divider(height: 1, indent: 56),
                    _LinkTile(
                      icon: Icons.forum_outlined,
                      label: 'Reddit',
                      subtitle: 'r/DeroGold',
                      url: _kRedditUrl,
                      onTap: () => _open(_kRedditUrl),
                    ),
                    const Divider(height: 1, indent: 56),
                    _LinkTile(
                      icon: Icons.article_outlined,
                      label: 'Medium',
                      subtitle: '@DeroGold',
                      url: _kMediumUrl,
                      onTap: () => _open(_kMediumUrl),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // License / disclaimer
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr?.license ?? 'License', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Text(
                        tr?.licenseText ??
                        'Released under the GNU General Public License v3.0.\n'
                        'Use at your own risk. Always back up your seed phrase.',
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final String url;
  final VoidCallback onTap;

  const _LinkTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.url,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20, color: kTextSecondary),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.open_in_new, size: 14, color: kTextSecondary),
      onTap: onTap,
    );
  }
}
