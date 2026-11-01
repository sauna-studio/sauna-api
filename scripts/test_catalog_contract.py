"""The public catalog contract cannot select private visibility or expose identities."""
import unittest

from validate_openapi import load_contract


class CatalogContractTests(unittest.TestCase):
    def test_anonymous_contract_has_only_public_selectors_and_bounded_projection(self):
        document = load_contract()
        base = '/facilities/{facilityID}/products'
        listing = document['paths'][base]['get']
        detail = document['paths'][base + '/{productID}']['get']
        self.assertEqual(listing['security'], [])
        self.assertEqual(detail['security'], [])
        self.assertEqual({p['name'] for p in listing['parameters']}, {'facilityID', 'kind', 'limit'})
        self.assertEqual({p['name'] for p in detail['parameters']}, {'facilityID', 'productID'})
        schema = document['components']['schemas']['ProductOffering']
        self.assertFalse(schema['additionalProperties'])
        self.assertEqual(set(schema['properties']), {
            'facilityID', 'id', 'name', 'kind', 'capacity', 'minimumDurationMinutes',
            'maximumDurationMinutes', 'minimumNights', 'maximumNights', 'published'})
        self.assertEqual(document['components']['schemas']['ProductOfferings']['properties']['products']['maxItems'], 100)

    def test_staff_publication_edit_requires_session_origin_csrf_and_all_conditions(self):
        document = load_contract()
        path = '/staff/facilities/{facilityID}/products/{productID}/offering'
        for operation in document['paths'][path].values():
            self.assertEqual(operation['security'], [{'StaffSession': []}])
            origin = next(p for p in operation['parameters'] if p['name'] == 'Origin')
            self.assertTrue(origin['required'])
            self.assertEqual(origin['schema']['enum'], ['http://localhost:5174'])
        edit = document['paths'][path]['put']
        csrf = next(p for p in edit['parameters'] if p['name'] == 'X-Sauna-CSRF')
        self.assertTrue(csrf['required'])
        body = document['components']['schemas']['ProductOfferingRequest']
        self.assertFalse(body['additionalProperties'])
        self.assertEqual(set(body['required']), {
            'kind', 'capacity', 'minimumDurationMinutes', 'maximumDurationMinutes',
            'minimumNights', 'maximumNights', 'published'})
        self.assertEqual(set(body['properties']), set(body['required']))
