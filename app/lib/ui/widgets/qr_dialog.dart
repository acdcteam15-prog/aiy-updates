import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'common.dart';

/// A QR code for a link: the people you give the app to scan it and download.
Future<void> showQrDialog(BuildContext context, String url) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Scan to download'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(data: url, size: 220, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 10),
          SelectableText(url, style: Theme.of(c).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text('A private repository needs the person to be signed in to GitHub.', style: Theme.of(c).textTheme.bodySmall?.copyWith(color: Theme.of(c).colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              snack(c, 'Link copied');
            },
            child: const Text('Copy the link'),
          ),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
        ],
      ),
    );
