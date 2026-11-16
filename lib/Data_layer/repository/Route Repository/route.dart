import '../Attraction Repository/attraction.dart';
import '../../service/Navigation Service/navigation.dart';

class RouteRepository {
  final NavigationService navigationService;

  RouteRepository(this.navigationService);

  Map<String, dynamic> buildRouteInfo(MysteryPlaceOption option) {
    return navigationService.buildNavigationData(
      distanceMeter: option.distanceMeter,
      direction: option.direction,
    );
  }
}