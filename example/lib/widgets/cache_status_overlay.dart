import 'package:flutter/material.dart';

class CacheStatusOverlay extends StatelessWidget {
  final Map<String, String> statuses;
  final String currentUrl;

  const CacheStatusOverlay({
    super.key,
    required this.statuses,
    required this.currentUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'CACHE STATUS',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          ...statuses.entries.take(5).map((entry) {
            final isCurrent = entry.key == currentUrl;
            final color = entry.value == 'complete'
                ? Colors.green
                : entry.value == 'partial'
                ? Colors.orange
                : Colors.red;

            final filename = entry.key.split('/').last;
            final shortName = filename.length > 15
                ? '${filename.substring(0, 12)}...'
                : filename;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${isCurrent ? "> " : ""}$shortName',
                  style: TextStyle(
                    color: isCurrent ? Colors.white : Colors.white54,
                    fontSize: 9,
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}
