import 'package:auto_route/auto_route.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zephyr/config/global/global.dart';
import 'package:zephyr/page/more/more.dart';
import 'package:zephyr/widgets/navigation/glass_navigation_insets.dart';

@RoutePage()
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: GlassNavigationInsets.bottomOf(context) == 0,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 768),
            child: ListView(
              padding: GlassNavigationInsets.bottomOf(context) > 0
                  ? EdgeInsets.only(
                      bottom: GlassNavigationInsets.bottomOf(context),
                    )
                  : null,
              children: [
                const SizedBox(height: 24),
                _buildHeader(context),
                const SettingsWidget(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Image.asset('asset/image/app-icon.png', width: 88, height: 88),
        ),
        const SizedBox(height: 12),
        Text(
          appName,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
