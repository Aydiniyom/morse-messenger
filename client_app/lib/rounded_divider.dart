import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

class RoundedDivider extends StatelessWidget {
  const RoundedDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsetsGeometry.symmetric(horizontal: 15),
        child: Container(
          width: double.infinity,
          height: 2,
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      )
    );
  }
}