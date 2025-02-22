//
//  PaymentSheetFormFactory.swift
//  StripeiOS
//
//  Created by Yuki Tokuhiro on 6/9/21.
//  Copyright © 2021 Stripe, Inc. All rights reserved.
//

import UIKit
@_spi(STP) import StripeCore
import SwiftUI
@_spi(STP) import StripeUICore

/**
 This class creates a FormElement for a given payment method type and binds the FormElement's field values to an
 `IntentConfirmParams`.
 */
class PaymentSheetFormFactory {
    enum SaveMode {
        /// We can't save the PaymentMethod. e.g., Payment mode without a customer
        case none
        /// The customer chooses whether or not to save the PaymentMethod. e.g., Payment mode
        case userSelectable
        /// `setup_future_usage` is set on the PaymentIntent or Setup mode
        case merchantRequired
    }
    let saveMode: SaveMode
    let paymentMethod: STPPaymentMethodType
    let intent: Intent
    let configuration: PaymentSheet.Configuration
    let addressSpecProvider: AddressSpecProvider
    let offerSaveToLinkWhenSupported: Bool
    let linkAccount: PaymentSheetLinkAccount?

    var canSaveToLink: Bool {
        return (
            intent.supportsLink &&
            paymentMethod == .card &&
            saveMode != .merchantRequired
        )
    }

    init(
        intent: Intent,
        configuration: PaymentSheet.Configuration,
        paymentMethod: STPPaymentMethodType,
        addressSpecProvider: AddressSpecProvider = .shared,
        offerSaveToLinkWhenSupported: Bool = false,
        linkAccount: PaymentSheetLinkAccount? = nil
    ) {
        // Set the current elements theme
        ElementsUITheme.current = configuration.appearance.asElementsTheme
        
        switch intent {
        case let .paymentIntent(paymentIntent):
            let merchantRequiresSave = paymentIntent.setupFutureUsage != .none
            let hasCustomer = configuration.customer != nil
            let isPaymentMethodSaveable = PaymentSheet.supportsSaveAndReuse(paymentMethod: paymentMethod, configuration: configuration, intent: intent)
            switch (merchantRequiresSave, hasCustomer, isPaymentMethodSaveable) {
            case (true, _, _):
                saveMode = .merchantRequired
            case (false, true, true):
                saveMode = .userSelectable
            case (false, true, false):
                fallthrough
            case (false, false, _):
                saveMode = .none
            }
        case .setupIntent:
            saveMode = .merchantRequired
        }
        self.intent = intent
        self.configuration = configuration
        self.paymentMethod = paymentMethod
        self.addressSpecProvider = addressSpecProvider
        self.offerSaveToLinkWhenSupported = offerSaveToLinkWhenSupported
        self.linkAccount = linkAccount
    }
    
    func make() -> PaymentMethodElement {
        // We have three ways to create the form for a payment method
        // 1. Custom, one-off forms
        if paymentMethod == .card {
            return makeCard()
        } else if paymentMethod == .linkInstantDebit {
            return ConnectionsElement()
        } else if paymentMethod == .USBankAccount {
            return makeUSBankAccount(merchantName: configuration.merchantDisplayName)
        }

        // 2. Element-based forms defined in JSON
        if let formElement = makeFormElementFromJSONSpecs() {
            return formElement
        }
        
        // 3. Element-based forms defined in code
        let formElements: [Element] = {
            switch paymentMethod {
            case .bancontact:
                return makeBancontact()
            case .sofort:
                return makeSofort()
            case .SEPADebit:
                return makeSepa()
            case .afterpayClearpay:
                return makeAfterpayClearpay()
            case .klarna:
                return makeKlarna()
            case .affirm:
                return makeAffirm()
            case .AUBECSDebit:
                return makeAUBECSDebit()
            case .payPal:
                return []
            default:
                fatalError()
            }
        }()

        return FormElement(autoSectioningElements: formElements)
    }
}

extension PaymentSheetFormFactory {
    // MARK: - DRY Helper funcs
    
    func makeFullName() -> PaymentMethodElementWrapper<TextFieldElement> {
        let element = TextFieldElement.Address.makeFullName(defaultValue: configuration.defaultBillingDetails.name)
        return PaymentMethodElementWrapper(element) { textField, params in
            params.paymentMethodParams.nonnil_billingDetails.name = textField.text
            return params
        }
    }
    
    func makeEmail() -> PaymentMethodElementWrapper<TextFieldElement>  {
        let element = TextFieldElement.Address.makeEmail(defaultValue: configuration.defaultBillingDetails.email)
        return PaymentMethodElementWrapper(element) { textField, params in
            params.paymentMethodParams.nonnil_billingDetails.email = textField.text
            return params
        }
    }

    func makeNameOnAccount() -> PaymentMethodElementWrapper<TextFieldElement> {
        let element = TextFieldElement.Address.makeNameOnAccount(defaultValue: configuration.defaultBillingDetails.name)
        return PaymentMethodElementWrapper(element) { textField, params in
            params.paymentMethodParams.nonnil_billingDetails.name = textField.text
            return params
        }
    }

    func makeBSB() -> PaymentMethodElementWrapper<TextFieldElement> {
        let element = TextFieldElement.Account.makeBSB(defaultValue: nil)
        return PaymentMethodElementWrapper(element) { textField, params in
            let bsbNumberText = BSBNumber(number: textField.text).bsbNumberText()
            params.paymentMethodParams.auBECSDebit?.bsbNumber = bsbNumberText
            return params
        }
    }

    func makeAUBECSAccountNumber() -> PaymentMethodElementWrapper<TextFieldElement> {
        let element = TextFieldElement.Account.makeAUBECSAccountNumber(defaultValue: nil)
        return PaymentMethodElementWrapper(element) { textField, params in
            params.paymentMethodParams.auBECSDebit?.accountNumber = textField.text
            return params
        }
    }

    func makeMandate() -> StaticElement {
        return StaticElement(view: SepaMandateView(merchantDisplayName: configuration.merchantDisplayName))
    }
    
    func makeSaveCheckbox(
        label: String = String.Localized.save_for_future_payments,
        didToggle: ((Bool) -> ())? = nil
    ) -> PaymentMethodElementWrapper<SaveCheckboxElement> {
        let element = SaveCheckboxElement(
            appearance: configuration.appearance,
            label: label,
            isSelectedByDefault: configuration.savePaymentMethodOptInBehavior.isSelectedByDefault,
            didToggle: didToggle
        )
        return PaymentMethodElementWrapper(element) { checkbox, params in
            if !checkbox.checkboxButton.isHidden {
                params.shouldSavePaymentMethod = checkbox.checkboxButton.isSelected
            }
            return params
        }
    }
    
    func makeBillingAddressSection(collectionMode: AddressSectionElement.CollectionMode = .all) -> PaymentMethodElementWrapper<AddressSectionElement> {
        let section = AddressSectionElement(
            title: String.Localized.billing_address,
            addressSpecProvider: addressSpecProvider,
            defaults: configuration.defaultBillingDetails.address.addressSectionDefaults,
            collectionMode: collectionMode
        )
        return PaymentMethodElementWrapper(section) { section, params in
            guard section.isValidAddress else {
                return nil
            }
            if let line1 = section.line1 {
                params.paymentMethodParams.nonnil_billingDetails.nonnil_address.line1 = line1.text
            }
            if let line2 = section.line2 {
                params.paymentMethodParams.nonnil_billingDetails.nonnil_address.line2 = line2.text
            }
            if let city = section.city {
                params.paymentMethodParams.nonnil_billingDetails.nonnil_address.city = city.text
            }
            if let state = section.state {
                params.paymentMethodParams.nonnil_billingDetails.nonnil_address.state = state.text
            }
            if let postalCode = section.postalCode {
                params.paymentMethodParams.nonnil_billingDetails.nonnil_address.postalCode = postalCode.text
            }
            params.paymentMethodParams.nonnil_billingDetails.nonnil_address.country = section.selectedCountryCode

            return params
        }
    }

    // MARK: - PaymentMethod form definitions

    func makeUSBankAccount(merchantName: String) -> PaymentMethodElement {
        let isSaving = BoolReference()
        let saveCheckbox = makeSaveCheckbox(
            label: String(format: STPLocalizedString("Save this account for future %@ payments", "Prompt next to checkbox to save bank account."), merchantName)) { value in
                isSaving.value = value
            }
        let shouldDisplaySaveCheckbox: Bool = saveMode == .userSelectable && !canSaveToLink
        isSaving.value = shouldDisplaySaveCheckbox ? configuration.savePaymentMethodOptInBehavior.isSelectedByDefault : saveMode == .merchantRequired
        return USBankAccountPaymentMethodElement(titleElement: makeUSBankAccountCopyLabel(),
                                                 nameElement: makeFullName(),
                                                 emailElement: makeEmail(),
                                                 checkboxElement: shouldDisplaySaveCheckbox ? saveCheckbox : nil,
                                                 savingAccount: isSaving,
                                                 merchantName: merchantName)
    }

    func makeBancontact() -> [PaymentMethodElement] {
        let name = makeFullName()
        let email = makeEmail()
        let mandate = makeMandate()
        let save = makeSaveCheckbox() { selected in
            email.element.isOptional = !selected
            mandate.isHidden = !selected
        }
        
        switch saveMode {
        case .none:
            return [name]
        case .userSelectable:
            return [name, email, save, mandate]
        case .merchantRequired:
            return [name, email, mandate]
        }
    }
    
    func makeSofort() -> [PaymentMethodElement] {
        let locale = Locale.current
        let countryCodes = locale.sortedByTheirLocalizedNames(
            /// A hardcoded list of countries that support Sofort
            ["AT", "BE", "DE", "IT", "NL", "ES"]
        )
        let country = PaymentMethodElementWrapper(DropdownFieldElement.Address.makeCountry(
            label: String.Localized.country,
            countryCodes: countryCodes,
            defaultCountry: configuration.defaultBillingDetails.address.country,
            locale: locale
        )) { dropdown, params in
            let sofortParams = params.paymentMethodParams.sofort ?? STPPaymentMethodSofortParams()
            sofortParams.country = countryCodes[dropdown.selectedIndex]
            params.paymentMethodParams.sofort = sofortParams
            return params
        }
        let name = makeFullName()
        let email = makeEmail()
        let mandate = makeMandate()
        let save = makeSaveCheckbox(didToggle: { selected in
            name.element.isOptional = !selected
            email.element.isOptional = !selected
            mandate.isHidden = !selected
        })
        switch saveMode {
        case .none:
            return [country]
        case .userSelectable:
            return [name, email, country, save, mandate]
        case .merchantRequired:
            return [name, email, country, mandate]
        }
    }

    func makeSepa() -> [PaymentMethodElement] {
        let iban = PaymentMethodElementWrapper(TextFieldElement.makeIBAN()) { iban, params in
            let sepa = params.paymentMethodParams.sepaDebit ?? STPPaymentMethodSEPADebitParams()
            sepa.iban = iban.text
            params.paymentMethodParams.sepaDebit = sepa
            return params
        }
        let name = makeFullName()
        let email = makeEmail()
        let mandate = makeMandate()
        let save = makeSaveCheckbox(didToggle: { selected in
            email.element.isOptional = !selected
            mandate.isHidden = !selected
        })
        let address = makeBillingAddressSection()
        switch saveMode {
        case .none:
            return [name, email, iban, address, mandate]
        case .userSelectable:
            return [name, email, iban, address, save, mandate]
        case .merchantRequired:
            return [name, email, iban, address, mandate]
        }
    }

    func makeAfterpayClearpay() -> [PaymentMethodElement] {
        guard case let .paymentIntent(paymentIntent) = intent else {
            assertionFailure()
            return []
        }
        let priceBreakdownView = StaticElement(
            view: AfterpayPriceBreakdownView(amount: paymentIntent.amount, currency: paymentIntent.currency)
        )
        return [priceBreakdownView, makeFullName(), makeEmail(), makeBillingAddressSection()]
    }
    
    func makeKlarna() -> [PaymentMethodElement] {
        guard case let .paymentIntent(paymentIntent) = intent else {
            assertionFailure("Klarna only be used with a PaymentIntent")
            return []
        }

        let countryCodes = Locale.current.sortedByTheirLocalizedNames(
            KlarnaHelper.availableCountries(currency: paymentIntent.currency)
        )
        let country = PaymentMethodElementWrapper(DropdownFieldElement.Address.makeCountry(
            label: String.Localized.country,
            countryCodes: countryCodes,
            defaultCountry: configuration.defaultBillingDetails.address.country,
            locale: Locale.current
        )) { dropdown, params in
            let address = STPPaymentMethodAddress()
            address.country = countryCodes[dropdown.selectedIndex]
            params.paymentMethodParams.nonnil_billingDetails.address = address
            return params
        }

        return [makeKlarnaCopyLabel(), makeEmail(), country]
    }

    func makeAUBECSDebit() -> [PaymentMethodElement] {
        let mandate = StaticElement(view: AUBECSLegalTermsView(configuration: configuration))
        return [makeBSB(), makeAUBECSAccountNumber(), makeEmail(), makeNameOnAccount(), mandate]
    }

    func makeAffirm() -> [PaymentMethodElement] {
        let label = StaticElement(view: AffirmCopyLabel())
        return [label]
    }
    
    private func makeKlarnaCopyLabel() -> StaticElement {
        let text = KlarnaHelper.canBuyNow()
        ? STPLocalizedString("Buy now or pay later with Klarna.", "Klarna buy now or pay later copy")
        : STPLocalizedString("Pay later with Klarna.", "Klarna pay later copy")
        return makeSectionTitleLabelWith(text: text)
    }

    private func makeUSBankAccountCopyLabel() -> StaticElement {
        return makeSectionTitleLabelWith(text: STPLocalizedString("Pay with your bank account in just a few steps.",
                                                                  "US Bank Account copy title for Mobile payment element form"))
    }

    private func makeSectionTitleLabelWith(text: String) -> StaticElement {
        let label = UILabel()
        label.text = text
        label.font = ElementsUITheme.current.fonts.subheadline
        label.textColor = ElementsUITheme.current.colors.secondaryText
        label.numberOfLines = 0
        return StaticElement(view: label)
    }
}

// MARK: - Extension helpers

extension FormElement {
    /// Conveniently nests single TextField and DropdownFields in a Section
    convenience init(autoSectioningElements: [Element]) {
        let elements: [Element] = autoSectioningElements.map {
            if $0 is PaymentMethodElementWrapper<TextFieldElement> || $0 is PaymentMethodElementWrapper<DropdownFieldElement> {
                return SectionElement($0)
            }
            return $0
        }
        self.init(elements: elements)
    }
}

extension STPPaymentMethodBillingDetails {
    var nonnil_address: STPPaymentMethodAddress {
        guard let address = address else {
            let address = STPPaymentMethodAddress()
            self.address = address
            return address
        }
        return address
    }
}

private extension PaymentSheet.Address {
    var addressSectionDefaults: AddressSectionElement.Defaults {
        return .init(
            city: city,
            country: country,
            line1: line1,
            line2: line2,
            postalCode: postalCode,
            state: state
        )
    }
}

extension PaymentSheet.Appearance {

    /// Creates an `ElementsUITheme` based on this PaymentSheet appearance
    var asElementsTheme: ElementsUITheme {
        var theme = ElementsUITheme.default

        var colors = ElementsUITheme.Color()
        colors.primary = self.colors.primary
        colors.parentBackground = self.colors.background
        colors.background = self.colors.componentBackground
        colors.bodyText = self.colors.text
        colors.border = self.colors.componentBorder
        colors.divider = self.colors.componentDivider
        colors.textFieldText = self.colors.componentText
        colors.secondaryText = self.colors.textSecondary
        colors.placeholderText = self.colors.componentPlaceholderText
        colors.danger = self.colors.danger

        theme.borderWidth = borderWidth
        theme.cornerRadius = cornerRadius
        theme.shadow = shadow.asElementThemeShadow

        var fonts = ElementsUITheme.Font()
        fonts.subheadline = scaledFont(for: font.base.regular, style: .subheadline, maximumPointSize: 20)
        fonts.subheadlineBold = scaledFont(for: font.base.bold, style: .subheadline, maximumPointSize: 20)
        fonts.sectionHeader = scaledFont(for: font.base.medium, style: .footnote, maximumPointSize: 18)
        fonts.caption = scaledFont(for: font.base.regular, style: .caption1, maximumPointSize: 20)

        theme.colors = colors
        theme.fonts = fonts

        return theme
    }
}

extension PaymentSheet.Appearance.Shadow {

    /// Creates an `ElementsUITheme.Shadow` based on this PaymentSheet appearance shadow
    var asElementThemeShadow: ElementsUITheme.Shadow? {
        return ElementsUITheme.Shadow(color: color, opacity: opacity, offset: offset)
    }

    init(elementShadow: ElementsUITheme.Shadow) {
        self.color = elementShadow.color
        self.opacity = elementShadow.opacity
        self.offset = elementShadow.offset
    }
}
