/**
 * Validation utilities for the Demo CRUD API
 */

const VALID_CATEGORIES = ["electronics", "books", "clothing", "food", "other"];

/**
 * Validates an item payload
 * @param {Object} body - Request body to validate
 * @returns {Object} - { valid: true } or { valid: false, errors: [...] }
 */
function validateItem(body) {
  const errors = [];

  // Validate name: required, string, 1-100 chars
  if (body.name === undefined || body.name === null) {
    errors.push({ field: "name", message: "name is required" });
  } else if (typeof body.name !== "string") {
    errors.push({ field: "name", message: "name must be a string" });
  } else if (body.name.length < 1 || body.name.length > 100) {
    errors.push({ field: "name", message: "name must be between 1 and 100 characters" });
  }

  // Validate description: optional, string, max 500 chars
  if (body.description !== undefined && body.description !== null) {
    if (typeof body.description !== "string") {
      errors.push({ field: "description", message: "description must be a string" });
    } else if (body.description.length > 500) {
      errors.push({ field: "description", message: "description must be at most 500 characters" });
    }
  }

  // Validate price: required, number, must be > 0
  if (body.price === undefined || body.price === null) {
    errors.push({ field: "price", message: "price is required" });
  } else if (typeof body.price !== "number") {
    errors.push({ field: "price", message: "price must be a number" });
  } else if (body.price <= 0) {
    errors.push({ field: "price", message: "price must be greater than 0" });
  }

  // Validate category: required, must be one of VALID_CATEGORIES
  if (body.category === undefined || body.category === null) {
    errors.push({ field: "category", message: "category is required" });
  } else if (typeof body.category !== "string") {
    errors.push({ field: "category", message: "category must be a string" });
  } else if (!VALID_CATEGORIES.includes(body.category)) {
    errors.push({
      field: "category",
      message: `category must be one of: ${VALID_CATEGORIES.join(", ")}`
    });
  }

  if (errors.length > 0) {
    return { valid: false, errors };
  }

  return { valid: true };
}

module.exports = { validateItem, VALID_CATEGORIES };
