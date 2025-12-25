/// Form validation utilities for consistent validation across the app

/// Email validation regex pattern
final RegExp _emailRegex = RegExp(
  r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
);

/// Phone number validation regex (basic pattern - accepts digits, spaces, dashes, parentheses)
final RegExp _phoneRegex = RegExp(r'^[\d\s\-\(\)\+]{10,15}$');

/// Validates email format
String? validateEmail(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Email is required';
  }

  final email = value.trim();
  if (!_emailRegex.hasMatch(email)) {
    return 'Please enter a valid email address';
  }

  return null;
}

/// Validates phone number format
String? validatePhoneNumber(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Phone number is required';
  }

  final phone = value.trim();
  // Remove common formatting characters for validation
  final digitsOnly = phone.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

  if (digitsOnly.length < 10) {
    return 'Phone number must be at least 10 digits';
  }

  if (digitsOnly.length > 15) {
    return 'Phone number must be at most 15 digits';
  }

  if (!_phoneRegex.hasMatch(phone)) {
    return 'Please enter a valid phone number';
  }

  return null;
}

/// Validates password strength
String? validatePassword(String? value, {int minLength = 3}) {
  if (value == null || value.isEmpty) {
    return 'Password is required';
  }

  if (value.length < minLength) {
    return 'Password must be at least $minLength characters long';
  }

  return null;
}

/// Validates password confirmation matches password
String? validatePasswordConfirmation(String? value, String? password) {
  if (value == null || value.isEmpty) {
    return 'Please confirm your password';
  }

  if (value != password) {
    return 'Passwords do not match';
  }

  return null;
}

/// Validates username
String? validateUsername(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Username is required';
  }

  final username = value.trim();
  if (username.length < 2) {
    return 'Username must be at least 2 characters long';
  }

  if (username.length > 30) {
    return 'Username must be at most 30 characters long';
  }

  // Allow alphanumeric and underscore
  if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(username)) {
    return 'Username can only contain letters, numbers, and underscores';
  }

  return null;
}

/// Validates required field
String? validateRequired(String? value, {String fieldName = 'This field'}) {
  if (value == null || value.trim().isEmpty) {
    return '$fieldName is required';
  }
  return null;
}

/// Validates number input
String? validateNumber(
  String? value, {
  int? min,
  int? max,
  String fieldName = 'Number',
}) {
  if (value == null || value.trim().isEmpty) {
    return '$fieldName is required';
  }

  final number = int.tryParse(value.trim());
  if (number == null) {
    return 'Please enter a valid number';
  }

  if (min != null && number < min) {
    return '$fieldName must be at least $min';
  }

  if (max != null && number > max) {
    return '$fieldName must be at most $max';
  }

  return null;
}
