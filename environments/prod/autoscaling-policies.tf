########################
# Auto Scaling Policies - Escalado Automático basado en CPU
########################

# Target Tracking Policy: Mantener CPU promedio en 70%
resource "aws_autoscaling_policy" "target_tracking_cpu" {
  name                   = "${var.name}-target-tracking-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 70.0 # Escala cuando CPU promedio > 70%

    # Nota: Target Tracking no soporta cooldowns personalizados
    # AWS usa cooldowns por defecto (~60s scale out, ~300s scale in)
  }
}

# Opcional: Step Scaling para casos extremos (CPU > 90%)
resource "aws_autoscaling_policy" "step_scaling_cpu" {
  name                   = "${var.name}-step-scaling-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 10
  }

  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = 10
  }
}

# Alarm para Step Scaling (CPU > 90% = emergencia)
resource "aws_cloudwatch_metric_alarm" "cpu_scale_out_emergency" {
  alarm_name          = "${var.name}-cpu-scale-out-emergency"
  alarm_description   = "Scale out aggressively when CPU > 90%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 90

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.step_scaling_cpu.arn]
}

########################
# Outputs
########################

output "autoscaling_policy_arns" {
  description = "ARNs de las políticas de Auto Scaling"
  value = {
    target_tracking = aws_autoscaling_policy.target_tracking_cpu.arn
    step_scaling    = aws_autoscaling_policy.step_scaling_cpu.arn
  }
}
