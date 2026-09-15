import 'package:flutter/material.dart';
import '../widgets/trip_summary.dart';
import 'package:flutter/widget_previews.dart';
import 'home_screen.dart';

class DrivingReportScreen extends StatelessWidget {
  final TripSummary summary;

  const DrivingReportScreen({
    super.key,
    required this.summary,
  });

  String _letterGrade(double grade) {
  return switch (grade) {
    >= 90 => 'A',
    >= 80 => 'B',
    >= 70 => 'C',
    >= 60 => 'D',
    _ => 'F',
  };
}

  String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours hr $minutes min';
    }

    return '$minutes min $seconds sec';
  }


//Gets the lowest scoring catagory to provide suggestions/tips to the user,
//should be future proofed to include other catagories.
({String category, double score}) _getLowestScore(TripSummary summary) {
  final scores = {
    'speed': summary.properSpeedGrade,
    //'braking': summary.brakingGrade,
    //'acceleration': summary.acceleratingGrade,
    //'turning': summary.turningGrade,
    //'focusedDriving': summary.focusedDrivingGrade,
  };

  final lowest =
      scores.entries.reduce((a, b) => a.value < b.value ? a : b);

  return (
    category: lowest.key,
    score: lowest.value,
  );
}

  //Suggerstion/Tips based on catagory score
  String _getSuggestion(String category, double score) {
  switch (category) {
    case 'speed':
      if (score >= 90) {
        return 'Great job Staying within the speed limit!';
      } else if (score >= 80) {
        return 'Nice speed control, make sure to stay consistent.';
      } else if (score >= 70) {
        return 'Looks like you could improve your speed control, try to remember posted speed limits.';
      } else if (score >= 60) {
        return 'Try to reduce how often you go over the posted speed limit.';
      } else {
        return 'Focus on staying within the speed limit, speeding is extremely dangerous!';
      }

    default:
      return 'Keep practicing safe driving habits.';

    //For future implementation of other categories  
    //case 'braking':
    //case 'acceleration':
    //case 'turning':
    //case 'focusedDriving': 
  }
}

  Color gradeColor(double grade) {
    if (grade >= 90) {
      return const Color.fromARGB(255, 104, 209, 72);
    } else if (grade >= 80) {
      return const Color.fromARGB(255, 127, 190, 68);
    } else if (grade >= 70) {
      return const Color.fromARGB(255, 249, 230, 57);
    } else if (grade >= 60) {
      return Colors.orange;
    } else {
      return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final letterGrade = _letterGrade(summary.overallGrade);
    final lowestScore = _getLowestScore(summary);
    final suggestion = _getSuggestion(lowestScore.category, lowestScore.score);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Driving Report'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                'Trip Complete!',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),


              //color coded circle with letter grade
              CircleAvatar(
                radius: 65,
                backgroundColor: gradeColor(summary.overallGrade),
                child: Text(
                  letterGrade,
                  style: const TextStyle(
                    fontSize: 65,
                    fontWeight: FontWeight.bold,
                    color: Color.fromARGB(255, 0, 0, 0),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              Text(
                'Overall Score: ${summary.overallGrade.toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 32),


              // Display trip summary information
              _ReportItem(
                icon: Icons.speed,
                title: 'Speed Limit Score',
                value: '${summary.properSpeedGrade.toStringAsFixed(0)}%',

              ),

              _ReportItem(
                icon: Icons.drive_eta,
                title: 'Distance Driven',
                value: '${summary.milesDriven.toStringAsFixed(1)} miles',
              ),

              _ReportItem(
                icon: Icons.access_time_rounded,
                title: 'Trip Duration',
                value: formatDuration(summary.elapsed),
              ),


              //suggestiom/tip box
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.lightbulb_outline_rounded),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Helpful Tip!',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(suggestion, style: const TextStyle(fontSize: 16)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              //Go home button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (_) => const HomePage(),
                      ),
                      (route) => false,
                    );
                  },
                  child: const Text('Return Home'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _ReportItem({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
